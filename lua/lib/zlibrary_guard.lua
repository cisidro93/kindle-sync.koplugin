local ButtonDialog = require("ui/widget/buttondialog")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = require("ffi/util").template

local ZlibraryGuard = {}
ZlibraryGuard.__index = ZlibraryGuard

local SIDELOAD_EXTENSIONS = {
    epub = true,
    mobi = true,
    azw3 = true,
    kfx = true,
    pdf = true,
    cbz = true,
    cbr = true,
    fb2 = true,
}

local DEFAULT_SIDELOAD_DIRS = {
    "/mnt/us/books",
    "/mnt/base-us/books",
}

function ZlibraryGuard:new(virtual_library, kindle_library)
    local instance = {
        virtual_library = virtual_library,
        kindle_library = kindle_library,
        cached_index = nil,
        cached_index_time = 0,
        index_ttl = 120,
        hooks_installed = false,
        orig_ui_create_item = nil,
        orig_ui_show_details = nil,
        orig_msd_get_items = nil,
        orig_download_run = nil,
        orig_download_fetch = nil,
    }
    setmetatable(instance, self)
    return instance
end

--- Decode basic HTML entities and strip formatting control characters.
--- @param str string|nil
--- @return string
function ZlibraryGuard.cleanText(str)
    if type(str) ~= "string" or str == "" then
        return ""
    end
    local cleaned = str
    if util and type(util.htmlEntitiesToUtf8) == "function" then
        local ok, res = pcall(util.htmlEntitiesToUtf8, cleaned)
        if ok and type(res) == "string" then
            cleaned = res
        end
    else
        cleaned = cleaned:gsub("&amp;", "&"):gsub("&quot;", '"'):gsub("&#0?39;", "'"):gsub("&apos;", "'"):gsub("&lt;", "<"):gsub("&gt;", ">")
    end
    -- Strip KOReader bidi/formatting private-use codepoints (\u{FFF1}..\u{FFF3})
    cleaned = cleaned:gsub("\239\191[\177-\179]", "")
    return cleaned:gsub("^%s+", ""):gsub("%s+$", "")
end

--- Format a book's authors field (table or string) into a display string.
--- @param authors table|string|nil
--- @return string
function ZlibraryGuard.formatAuthors(authors)
    if type(authors) == "table" then
        local parts = {}
        for _, a in ipairs(authors) do
            if type(a) == "string" and a ~= "" then
                table.insert(parts, a)
            end
        end
        return table.concat(parts, ", ")
    elseif type(authors) == "string" then
        return authors
    end
    return ""
end

--- Normalize a book title for full comparison.
--- Strips parenthetical series/edition tags, punctuation, and leading articles.
--- @param title string|nil
--- @return string
function ZlibraryGuard.normalizeTitle(title)
    local clean = ZlibraryGuard.cleanText(title):lower()
    if clean == "" then
        return ""
    end
    -- Remove parentheticals/brackets like "(Book 1)", "[Unabridged]", "(A Novel)"
    clean = clean:gsub("%b()", " "):gsub("%b[]", " ")
    -- Replace common connectors
    clean = clean:gsub("&", " and ")
    -- Keep only alphanumeric and spaces
    clean = clean:gsub("[^%w%s]", " ")
    clean = clean:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
    -- Strip leading English articles
    clean = clean:gsub("^the%s+", ""):gsub("^an%s+", ""):gsub("^a%s+", "")
    return clean:gsub("^%s+", ""):gsub("%s+$", "")
end

--- Extract the core title before any subtitle separator (":", " - ", " — ", " – ").
--- @param title string|nil
--- @return string
function ZlibraryGuard.extractCoreTitle(title)
    local clean = ZlibraryGuard.cleanText(title)
    if clean == "" then
        return ""
    end
    -- Strip parentheticals first
    local no_parens = clean:gsub("%b()", ""):gsub("%b[]", "")
    -- Split before colon or dash subtitle separators
    local core = no_parens:match("^(.-)%s*[:%-—–]%s+.+$") or no_parens
    local norm_core = ZlibraryGuard.normalizeTitle(core)
    if #norm_core >= 4 then
        return norm_core
    end
    return ZlibraryGuard.normalizeTitle(no_parens)
end

--- Extract normalized author tokens (words of length >= 3) for author matching.
--- @param authors table|string|nil
--- @return table: map of token -> true, and list of tokens
function ZlibraryGuard.extractAuthorTokens(authors)
    local raw = ZlibraryGuard.formatAuthors(authors)
    local clean = ZlibraryGuard.cleanText(raw):lower()
    if clean == "" or clean == "unknown author" or clean == "unknown" then
        return {}, {}
    end
    clean = clean:gsub("[^%w%s]", " ")
    local token_map = {}
    local token_list = {}
    for word in clean:gmatch("%w+") do
        if #word >= 3 and word ~= "and" and word ~= "the" and word ~= "with" then
            if not token_map[word] then
                token_map[word] = true
                table.insert(token_list, word)
            end
        end
    end
    return token_map, token_list
end

--- Check if two author token sets share at least one significant token (such as surname).
--- @param map_a table
--- @param list_a table
--- @param map_b table
--- @param list_b table
--- @return boolean
local function authorsOverlap(map_a, list_a, map_b, list_b)
    if #list_a == 0 or #list_b == 0 then
        -- If either side is missing author metadata, do not disqualify an exact title match
        return true
    end
    for _, tok in ipairs(list_a) do
        if map_b[tok] then
            return true
        end
    end
    return false
end

--- Parse a sideloaded filename like "Title - Author.epub" or "Author - Title.epub".
--- @param filepath string
--- @return table|nil
local function parseSideloadedFilename(filepath)
    local filename = filepath:match("([^/]+)$")
    if not filename then
        return nil
    end
    local stem, ext = filename:match("^(.+)%.([%w]+)$")
    if not stem or not ext then
        return nil
    end
    ext = ext:lower()
    if not SIDELOAD_EXTENSIONS[ext] then
        return nil
    end

    -- Skip KOReader temporary downloading files
    if filename:match("%.downloading$") then
        return nil
    end

    local title = stem
    local author = ""
    local part1, part2 = stem:match("^(.-)%s+%-%s+(.+)$")
    if part1 and part2 then
        title = part1
        author = part2
    end

    return {
        id = "local:" .. filepath,
        title = title:gsub("_", " "),
        authors = author ~= "" and { author:gsub("_", " ") } or {},
        source_path = filepath,
        format = ext:upper(),
        open_mode = "direct",
        is_sideloaded = true,
    }
end

--- Scan local sideload directories (e.g. /mnt/us/books and Z-Library download dir) for books.
--- @return table: list of book entries
function ZlibraryGuard:scanSideloadedBooks()
    local results = {}
    local seen_paths = {}
    local dirs = {}

    for _, d in ipairs(DEFAULT_SIDELOAD_DIRS) do
        table.insert(dirs, d)
    end

    if G_reader_settings and type(G_reader_settings.readSetting) == "function" then
        local zlib_cfg = G_reader_settings:readSetting("zlibrary")
        if type(zlib_cfg) == "table" and type(zlib_cfg.download_dir) == "string" and zlib_cfg.download_dir ~= "" then
            table.insert(dirs, zlib_cfg.download_dir)
        end
    end

    for _, dir in ipairs(dirs) do
        local attr = lfs.attributes(dir)
        if attr and attr.mode == "directory" then
            local ok, iter, dir_obj = pcall(lfs.dir, dir)
            if ok and iter then
                for entry in iter, dir_obj do
                    if entry ~= "." and entry ~= ".." then
                        local full_path = dir .. "/" .. entry
                        local norm_path = full_path:gsub("^/mnt/base%-us/", "/mnt/us/")
                        if not seen_paths[norm_path] then
                            local e_attr = lfs.attributes(full_path)
                            if e_attr and e_attr.mode == "file" then
                                local parsed = parseSideloadedFilename(full_path)
                                if parsed then
                                    seen_paths[norm_path] = true
                                    table.insert(results, parsed)
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return results
end

--- Build or return the cached lookup index of all Kindle + local books.
--- @param force boolean|nil
--- @return table
function ZlibraryGuard:getIndex(force)
    local now = os.time()
    if self.cached_index and not force and (now - self.cached_index_time) < self.index_ttl then
        return self.cached_index
    end

    local entries = {}
    local by_full_title = {}
    local by_core_title = {}
    local seen_ids = {}

    local function addBook(book)
        if type(book) ~= "table" or not book.title or book.title == "" then
            return
        end
        local key = book.id or book.source_path or book.title
        if seen_ids[key] then
            return
        end
        seen_ids[key] = true

        local full_norm = self.normalizeTitle(book.title)
        local core_norm = self.extractCoreTitle(book.title)
        if full_norm == "" then
            return
        end

        local author_map, author_list = self.extractAuthorTokens(book.authors or book.author)
        local record = {
            book = book,
            full_norm = full_norm,
            core_norm = core_norm,
            author_map = author_map,
            author_list = author_list,
            authors_str = self.formatAuthors(book.authors or book.author),
        }

        table.insert(entries, record)

        if not by_full_title[full_norm] then
            by_full_title[full_norm] = {}
        end
        table.insert(by_full_title[full_norm], record)

        if core_norm ~= "" then
            if not by_core_title[core_norm] then
                by_core_title[core_norm] = {}
            end
            table.insert(by_core_title[core_norm], record)
        end
    end

    if self.virtual_library then
        local books = nil
        if type(self.virtual_library.getOrderedBooks) == "function" then
            local ok, res = pcall(self.virtual_library.getOrderedBooks, self.virtual_library)
            if ok and type(res) == "table" then
                books = res
            end
        end
        if (not books or #books == 0) and self.virtual_library.library_index then
            local ok, res = pcall(self.virtual_library.library_index.getBooks, self.virtual_library.library_index, false)
            if ok and type(res) == "table" then
                books = res
            end
        end
        if type(books) == "table" then
            for _, b in ipairs(books) do
                addBook(b)
            end
        end
    end

    local sideloaded = self:scanSideloadedBooks()
    for _, b in ipairs(sideloaded) do
        addBook(b)
    end

    self.cached_index = {
        entries = entries,
        by_full_title = by_full_title,
        by_core_title = by_core_title,
    }
    self.cached_index_time = now
    return self.cached_index
end

--- Invalidate the cached index so the next lookup refreshes from VirtualLibrary.
function ZlibraryGuard:invalidateCache()
    self.cached_index = nil
    self.cached_index_time = 0
end

--- Find if a Z-Library book candidate matches a book already on the Kindle.
--- @param candidate table: { title = string, author = string|table, authors = table|string }
--- @return table|nil: matched Kindle book table
--- @return string|nil: "exact" or "similar"
function ZlibraryGuard:findMatch(candidate)
    if type(candidate) ~= "table" or type(candidate.title) ~= "string" or candidate.title == "" then
        return nil, nil
    end

    local full_norm = self.normalizeTitle(candidate.title)
    local core_norm = self.extractCoreTitle(candidate.title)
    if full_norm == "" then
        return nil, nil
    end

    local cand_author_map, cand_author_list = self.extractAuthorTokens(candidate.author or candidate.authors)
    local index = self:getIndex(false)

    -- 1. Check exact normalized title matches
    local full_matches = index.by_full_title[full_norm]
    if full_matches then
        for _, rec in ipairs(full_matches) do
            if authorsOverlap(cand_author_map, cand_author_list, rec.author_map, rec.author_list) then
                return rec.book, "exact"
            end
        end
        -- Full title matched, even if author metadata differed (e.g. translator or anthology)
        if #full_norm >= 6 then
            return full_matches[1].book, "similar"
        end
    end

    -- 2. Check core title matches (e.g. Z-Library has "Title: A Novel" and Kindle has "Title")
    if core_norm ~= "" then
        local core_matches = index.by_core_title[core_norm]
        if core_matches then
            for _, rec in ipairs(core_matches) do
                if authorsOverlap(cand_author_map, cand_author_list, rec.author_map, rec.author_list) then
                    -- If at least one author token explicitly overlaps (both have authors), it's an exact match
                    if #cand_author_list > 0 and #rec.author_list > 0 then
                        return rec.book, "exact"
                    elseif #core_norm >= 6 then
                        return rec.book, "exact"
                    end
                end
            end
            if #core_norm >= 8 then
                return core_matches[1].book, "similar"
            end
        end
    end

    -- 3. Check if one full title starts with the other and authors explicitly match
    if #cand_author_list > 0 and #full_norm >= 6 then
        for _, rec in ipairs(index.entries) do
            if #rec.author_list > 0 and authorsOverlap(cand_author_map, cand_author_list, rec.author_map, rec.author_list) then
                if rec.full_norm:sub(1, #full_norm + 1) == (full_norm .. " ") or full_norm:sub(1, #rec.full_norm + 1) == (rec.full_norm .. " ") then
                    return rec.book, "exact"
                end
            end
        end
    end

    return nil, nil
end

--- Search all local/Kindle books matching a user query string.
--- @param query string
--- @return table: list of matching book records
function ZlibraryGuard:searchLocalBooks(query)
    local norm_q = self.normalizeTitle(query)
    if norm_q == "" then
        return {}
    end

    local q_tokens = {}
    for word in norm_q:gmatch("%w+") do
        table.insert(q_tokens, word)
    end
    if #q_tokens == 0 then
        return {}
    end

    local index = self:getIndex(true)
    local results = {}
    for _, rec in ipairs(index.entries) do
        local haystack = rec.full_norm .. " " .. rec.authors_str:lower()
        local all_found = true
        for _, tok in ipairs(q_tokens) do
            if not haystack:find(tok, 1, true) then
                all_found = false
                break
            end
        end
        if all_found then
            table.insert(results, rec.book)
        end
    end

    return results
end

--- Format the inline badge shown on Z-Library search/browse rows.
--- @param matched_book table
--- @param match_type string
--- @return string
function ZlibraryGuard:formatBadge(matched_book, match_type)
    if not matched_book then
        return ""
    end
    if match_type == "exact" then
        local pct = tonumber(matched_book.percent_finished)
        if pct and pct > 0 then
            if pct <= 1 then
                pct = math.floor(pct * 100)
            else
                pct = math.floor(pct)
            end
            return string.format(_("[✅ ON KINDLE • %d%%] "), pct)
        end
        return _("[✅ ON KINDLE] ")
    end
    return _("[⚠️ SIMILAR ON KINDLE] ")
end

--- Decorate a Z-Library menu item table with an inline Kindle ownership badge.
--- @param item table
--- @param book_data table
--- @return table
function ZlibraryGuard:decorateMenuItem(item, book_data)
    if type(item) ~= "table" or type(book_data) ~= "table" then
        return item
    end
    local matched_book, match_type = self:findMatch(book_data)
    if matched_book and type(item.text) == "string" then
        local badge = self:formatBadge(matched_book, match_type)
        if badge ~= "" and not item.text:find(badge, 1, true) then
            item.text = badge .. item.text
        end
        item.kindle_match = matched_book
        item.kindle_match_type = match_type
    end
    return item
end

--- Open an existing Kindle book directly in KOReader.
--- @param book table
--- @return boolean
function ZlibraryGuard:openExistingBook(book)
    if not book then
        return false
    end
    local open_path = book.source_path
    if self.virtual_library and self.virtual_library.cache_manager and type(self.virtual_library.cache_manager.getCachePaths) == "function" then
        local cached = self.virtual_library.cache_manager:getCachePaths(book)
        if cached and type(self.virtual_library.isBookPrepared) == "function" and self.virtual_library:isBookPrepared(book) then
            open_path = cached
        end
    end
    if not open_path or open_path == "" then
        UIManager:show(InfoMessage:new({
            text = _("This book is in your Amazon Cloud library but not downloaded to device storage yet."),
            timeout = 4,
        }))
        return false
    end

    local filemanagerutil = require("apps/filemanager/filemanagerutil")
    local FileManager = require("apps/filemanager/filemanager")
    local ui = (self.kindle_library and self.kindle_library.ui) or FileManager.instance
    if ui then
        filemanagerutil.openFile(ui, open_path)
    else
        filemanagerutil.openFile(open_path)
    end
    return true
end

--- Show a duplicate-download confirmation dialog when the user attempts to download
--- a book from Z-Library that is already on their Kindle.
--- @param matched_book table
--- @param match_type string
--- @param zlib_book table
--- @param proceed_fn function
function ZlibraryGuard:promptDuplicateDownload(matched_book, match_type, zlib_book, proceed_fn)
    local existing_title = matched_book.title or _("Untitled")
    local existing_author = self.formatAuthors(matched_book.authors or matched_book.author)
    if existing_author == "" then
        existing_author = _("Unknown Author")
    end

    local pct = tonumber(matched_book.percent_finished)
    local progress_str = _("Unread")
    if pct and pct > 0 then
        if pct <= 1 then
            pct = math.floor(pct * 100)
        else
            pct = math.floor(pct)
        end
        progress_str = T(_("%1% read"), pct)
    end

    local source_label = matched_book.is_sideloaded and _("Sideloaded Book") or _("Kindle Library")
    local header_title = match_type == "exact" and _("⚠️ Book Already on Your Kindle!") or _("⚠️ Similar Book Found on Your Kindle!")

    local msg = T(
        _("%1\n\nExisting Book: %2\nAuthor: %3\nLocation: %4 (%5)\n\nAvoid using your Z-Library daily download quota on a duplicate:"),
        header_title,
        existing_title,
        existing_author,
        source_label,
        progress_str
    )

    local dialog
    local buttons = {}

    if matched_book.source_path and matched_book.source_path ~= "" then
        table.insert(buttons, {
            {
                text = _("📖 Open Existing Kindle Book"),
                callback = function()
                    UIManager:close(dialog)
                    self:openExistingBook(matched_book)
                end,
            },
        })
    end

    table.insert(buttons, {
        {
            text = _("⬇️ Download Anyway"),
            callback = function()
                UIManager:close(dialog)
                if type(zlib_book) == "table" then
                    zlib_book._kindle_bypass_dedupe = true
                end
                if type(proceed_fn) == "function" then
                    proceed_fn()
                end
            end,
        },
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(dialog)
            end,
        },
    })

    dialog = ButtonDialog:new({
        title = _("KindleOS • Z-Library Dedupe Guard"),
        text = msg,
        buttons = buttons,
    })
    UIManager:show(dialog)
end

--- Install runtime hooks into zlibrary.ui, zlibrary.multisearch_dialog, and zlibrary.download
--- if zlibrary.koplugin is loaded. Safe to call multiple times (idempotent).
--- @return boolean: true if hooks are installed
function ZlibraryGuard:installHooks()
    local guard = self

    -- 1. Hook zlibrary.ui
    local ui_mod = package.loaded["zlibrary.ui"]
    if not ui_mod then
        local ok, mod = pcall(require, "zlibrary.ui")
        if ok and type(mod) == "table" then
            ui_mod = mod
        end
    end
    if type(ui_mod) == "table" then
        if type(ui_mod.createBookMenuItem) == "function" and not ui_mod._kindle_guard_hooked then
            self.orig_ui_create_item = ui_mod.createBookMenuItem
            ui_mod.createBookMenuItem = function(book_data, parent_zlibrary_instance, is_show_cover)
                local item = guard.orig_ui_create_item(book_data, parent_zlibrary_instance, is_show_cover)
                return guard:decorateMenuItem(item, book_data)
            end
            ui_mod._kindle_guard_hooked = true
        end

        if type(ui_mod.showBookDetails) == "function" and not ui_mod._kindle_guard_details_hooked then
            self.orig_ui_show_details = ui_mod.showBookDetails
            ui_mod.showBookDetails = function(parent_zlibrary, book, clear_cache_callback)
                if type(book) == "table" then
                    local matched_book, match_type = guard:findMatch(book)
                    if matched_book then
                        local badge = match_type == "exact" and T(_('✅ ALREADY ON YOUR KINDLE: "%1"'), matched_book.title or "")
                            or T(_('⚠️ SIMILAR BOOK ON YOUR KINDLE: "%1"'), matched_book.title or "")
                        local desc = type(book.description) == "string" and book.description or ""
                        if not desc:find(badge, 1, true) then
                            book.description = badge .. (desc ~= "" and ("\n\n" .. desc) or "")
                        end
                    end
                end
                return guard.orig_ui_show_details(parent_zlibrary, book, clear_cache_callback)
            end
            ui_mod._kindle_guard_details_hooked = true
        end
    end

    -- 2. Hook zlibrary.multisearch_dialog (Most Popular & Recommended tabs)
    local msd_mod = package.loaded["zlibrary.multisearch_dialog"]
    if not msd_mod then
        local ok, mod = pcall(require, "zlibrary.multisearch_dialog")
        if ok and type(mod) == "table" then
            msd_mod = mod
        end
    end
    if type(msd_mod) == "table" and type(msd_mod._getMenuItems) == "function" and not msd_mod._kindle_guard_hooked then
        self.orig_msd_get_items = msd_mod._getMenuItems
        msd_mod._getMenuItems = function(dialog_self, books)
            local items = guard.orig_msd_get_items(dialog_self, books)
            if type(items) == "table" and type(books) == "table" then
                for i, item in ipairs(items) do
                    local book = books[item.book_index or i]
                    if book then
                        guard:decorateMenuItem(item, book)
                    end
                end
            end
            return items
        end
        msd_mod._kindle_guard_hooked = true
    end

    -- 3. Hook zlibrary.download (Duplicate download protection)
    local dl_mod = package.loaded["zlibrary.download"]
    if not dl_mod then
        local ok, mod = pcall(require, "zlibrary.download")
        if ok and type(mod) == "table" then
            dl_mod = mod
        end
    end
    if type(dl_mod) == "table" then
        if type(dl_mod.run) == "function" and not dl_mod._kindle_guard_run_hooked then
            self.orig_download_run = dl_mod.run
            dl_mod.run = function(zlib_self, book)
                if type(book) == "table" and not book._kindle_bypass_dedupe then
                    local matched_book, match_type = guard:findMatch(book)
                    if matched_book then
                        guard:promptDuplicateDownload(matched_book, match_type, book, function()
                            guard.orig_download_run(zlib_self, book)
                        end)
                        return
                    end
                end
                return guard.orig_download_run(zlib_self, book)
            end
            dl_mod._kindle_guard_run_hooked = true
        end

        if type(dl_mod.fetchDetailsThenDownload) == "function" and not dl_mod._kindle_guard_fetch_hooked then
            self.orig_download_fetch = dl_mod.fetchDetailsThenDownload
            dl_mod.fetchDetailsThenDownload = function(zlib_self, book_stub)
                if type(book_stub) == "table" and not book_stub._kindle_bypass_dedupe then
                    local matched_book, match_type = guard:findMatch(book_stub)
                    if matched_book then
                        guard:promptDuplicateDownload(matched_book, match_type, book_stub, function()
                            guard.orig_download_fetch(zlib_self, book_stub)
                        end)
                        return
                    end
                end
                return guard.orig_download_fetch(zlib_self, book_stub)
            end
            dl_mod._kindle_guard_fetch_hooked = true
        end
    end

    self.hooks_installed = (ui_mod and ui_mod._kindle_guard_hooked) == true
    if self.hooks_installed then
        logger.info("ZlibraryGuard: hooked zlibrary.koplugin search & download pipelines")
    end
    return self.hooks_installed
end

--- Activate ZlibraryGuard without scheduling background ticks during ReaderUI init.
function ZlibraryGuard:apply()
    self:installHooks()
end

--- Restore original zlibrary.koplugin functions on plugin teardown.
function ZlibraryGuard:unapply()
    local ui_mod = package.loaded["zlibrary.ui"]
    if type(ui_mod) == "table" then
        if self.orig_ui_create_item then
            ui_mod.createBookMenuItem = self.orig_ui_create_item
            self.orig_ui_create_item = nil
        end
        if self.orig_ui_show_details then
            ui_mod.showBookDetails = self.orig_ui_show_details
            self.orig_ui_show_details = nil
        end
        ui_mod._kindle_guard_hooked = nil
        ui_mod._kindle_guard_details_hooked = nil
    end

    local msd_mod = package.loaded["zlibrary.multisearch_dialog"]
    if type(msd_mod) == "table" and self.orig_msd_get_items then
        msd_mod._getMenuItems = self.orig_msd_get_items
        self.orig_msd_get_items = nil
        msd_mod._kindle_guard_hooked = nil
    end

    local dl_mod = package.loaded["zlibrary.download"]
    if type(dl_mod) == "table" then
        if self.orig_download_run then
            dl_mod.run = self.orig_download_run
            self.orig_download_run = nil
        end
        if self.orig_download_fetch then
            dl_mod.fetchDetailsThenDownload = self.orig_download_fetch
            self.orig_download_fetch = nil
        end
        dl_mod._kindle_guard_run_hooked = nil
        dl_mod._kindle_guard_fetch_hooked = nil
    end

    self.hooks_installed = false
end

--- Open Z-Library search directly (with dedupe hooks active), or open the local
--- Kindle library pre-check dialog first.
--- @param initial_query string|nil
function ZlibraryGuard:launchZlibrarySearch(initial_query)
    self:installHooks()
    self:invalidateCache()

    local ui_mod = package.loaded["zlibrary.ui"]
    if type(ui_mod) == "table" and type(ui_mod.showSearchDialog) == "function" then
        -- Find the active Zlibrary plugin instance if available
        local FileManager = require("apps/filemanager/filemanager")
        local ReaderUI = require("apps/reader/readerui")
        local host_ui = FileManager.instance or ReaderUI.instance
        if host_ui then
            for __, plugin in pairs(host_ui) do
                if type(plugin) == "table" and type(plugin.onZlibrarySearch) == "function" then
                    if initial_query and initial_query ~= "" then
                        ui_mod.showSearchDialog(plugin, initial_query)
                    else
                        plugin:onZlibrarySearch()
                    end
                    return true
                end
            end
        end
    end

    -- Fallback: broadcast ZlibrarySearch event through UIManager
    local handled = UIManager:broadcastEvent(Event:new("ZlibrarySearch"))
    if handled then
        return true
    end

    -- If Z-Library is not active, open the local library check dialog
    self:showLibraryCheckDialog(initial_query)
    return false
end

--- Show an interactive search dialog that checks the Kindle library first and
--- offers a 1-tap jump to Z-Library if the book is not already on the Kindle.
--- @param default_query string|nil
function ZlibraryGuard:showLibraryCheckDialog(default_query)
    local input_dialog
    input_dialog = InputDialog:new({
        title = _("Search Kindle & Z-Library (Dedupe Guard)"),
        input = default_query or "",
        input_hint = _("Enter book title or author..."),
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(input_dialog)
                    end,
                },
                {
                    text = _("🔍 Check Kindle First"),
                    is_enter_default = true,
                    callback = function()
                        local query = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        if not query or not query:match("%S") then
                            return
                        end
                        self:showCheckResults(query)
                    end,
                },
                {
                    text = _("🌐 Z-Library"),
                    callback = function()
                        local query = input_dialog:getInputText()
                        UIManager:close(input_dialog)
                        self:launchZlibrarySearch(query)
                    end,
                },
            },
        },
    })
    UIManager:show(input_dialog)
    input_dialog:onShowKeyboard()
end

--- Display local Kindle matches for a query, with an option to continue to Z-Library.
--- @param query string
function ZlibraryGuard:showCheckResults(query)
    local matches = self:searchLocalBooks(query)
    if #matches == 0 then
        local dialog
        dialog = ButtonDialog:new({
            title = _("Not Found on Your Kindle"),
            text = T(_('✅ "%1" is not in your Kindle Library yet.\n\nWould you like to search Z-Library for it now?'), query),
            buttons = {
                {
                    {
                        text = _('🌐 Search Z-Library for "%1"'):gsub("%%1", query),
                        callback = function()
                            UIManager:close(dialog)
                            self:launchZlibrarySearch(query)
                        end,
                    },
                },
                {
                    {
                        text = _("Close"),
                        callback = function()
                            UIManager:close(dialog)
                        end,
                    },
                },
            },
        })
        UIManager:show(dialog)
        return
    end

    local items = {}
    local results_menu

    table.insert(items, {
        text = T(_('🌐 Search Z-Library for "%1" anyway...'), query),
        bold = true,
        callback = function()
            if results_menu then
                UIManager:close(results_menu)
            end
            self:launchZlibrarySearch(query)
        end,
    })

    for __, book in ipairs(matches) do
        local title = book.title or _("Untitled")
        local authors_str = self.formatAuthors(book.authors or book.author)
        local author_suffix = authors_str ~= "" and (" — " .. authors_str) or ""
        local pct = tonumber(book.percent_finished)
        local pct_str = _("Unread")
        if pct and pct > 0 then
            pct_str = string.format("%d%%", pct <= 1 and math.floor(pct * 100) or math.floor(pct))
        end

        table.insert(items, {
            text = _("[✅ ON KINDLE] ") .. title .. author_suffix,
            help_text = T(_("Progress: %1 • Path: %2"), pct_str, book.source_path or ""),
            callback = function()
                if results_menu then
                    UIManager:close(results_menu)
                end
                self:openExistingBook(book)
            end,
        })
    end

    results_menu = Menu:new({
        title = T(_("Already on Kindle (%1 matches)"), #matches),
        item_table = items,
    })
    UIManager:show(results_menu)
end

return ZlibraryGuard
