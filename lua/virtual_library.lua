local BD = require("ui/bidi")
local Device = require("device")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

-- Kindle library model.
--
-- KOReader only ever sees real document paths: Kindle source files or the
-- plugin's cached converted EPUBs.
local VirtualLibrary = {}
VirtualLibrary.__index = VirtualLibrary

VirtualLibrary.VIRTUAL_LIBRARY_NAME = "Kindle Library"
VirtualLibrary.KINDLE_DOCUMENTS_ROOT = "/mnt/us/documents"

function VirtualLibrary:new(library_index)
    local instance = {
        library_index = library_index,
        settings = {},
        cache_manager = nil,
        books_by_id = {},
        books_by_real_path = {},
        mapping_attempted = false,
    }
    setmetatable(instance, self)
    return instance
end

function VirtualLibrary:setSettings(settings)
    self.settings = settings or {}
end

function VirtualLibrary:setCacheManager(cache_manager)
    self.cache_manager = cache_manager
end

local function isPathWithin(path, root)
    if type(path) ~= "string" or type(root) ~= "string" or root == "" then
        return false
    end
    return path == root or path:sub(1, #root + 1) == root .. "/"
end

local function isKindleSourcePath(path)
    if type(path) ~= "string" then
        return false
    end
    local extension = path:lower():match("%.([%w]+)$")
    return extension == "kfx" or extension == "azw" or extension == "azw3" or extension == "mobi"
end

local function sanitizeDisplayName(name)
    local cleaned = (name or "Untitled"):gsub("[/\\]+", " "):gsub("%s+", " ")
    cleaned = cleaned:gsub("^%s+", ""):gsub("%s+$", "")
    return cleaned ~= "" and cleaned or "Untitled"
end

function VirtualLibrary:buildMappings(force)
    self.mapping_attempted = true
    local books, err = self.library_index:getBooks(force)
    if not books then
        return nil, err
    end

    self.books_by_id = {}
    self.books_by_real_path = {}

    for _, book in ipairs(books) do
        self.books_by_id[book.id] = book
        if book.source_path then
            self.books_by_real_path[book.source_path] = book
        end
        -- Cache paths are deterministic even before the EPUB exists. Indexing
        -- them lets History/Collections and cold-start ReaderUI map a persisted
        -- cached EPUB back to its Kindle book after a restart.
        if self.cache_manager and type(self.cache_manager.getCachePaths) == "function" then
            local cached_path = self.cache_manager:getCachePaths(book)
            if cached_path then
                self.books_by_real_path[cached_path] = book
            end
        end
    end

    logger.info("KindlePlugin: built real-path mappings for", #books, "books")
    return books
end

function VirtualLibrary:refresh(force)
    return self:buildMappings(force)
end

function VirtualLibrary:isActive()
    return self.settings.enable_virtual_library ~= false
end

function VirtualLibrary:getBook(path_or_id)
    if not path_or_id then
        return nil
    end

    local book = self.books_by_id[path_or_id] or self.books_by_real_path[path_or_id]
    if book then
        return book
    end

    -- Reader startup, History, and Collections can reach us before the Kindle
    -- list has ever been opened in this process. Rebuild lazily only for paths
    -- that can plausibly belong to this plugin; the global open resolver must
    -- not turn an unrelated KOReader document open into a Kindle library scan.
    local cache_dir = self.settings.cache_dir
    if not cache_dir and self.cache_manager and self.cache_manager.getCacheDir then
        cache_dir = self.cache_manager:getCacheDir()
    end
    local should_build = type(path_or_id) == "string"
        and (
            path_or_id:match("^cc:")
            or path_or_id:match("^sha1:")
            or isPathWithin(path_or_id, cache_dir)
            or isPathWithin(path_or_id, self.KINDLE_DOCUMENTS_ROOT)
            or isKindleSourcePath(path_or_id)
        )
    if not self.mapping_attempted and should_build then
        local books = self:buildMappings(false)
        if books then
            return self.books_by_id[path_or_id] or self.books_by_real_path[path_or_id]
        end
    end

    return nil
end

function VirtualLibrary:getBlockedReasonText(book)
    local reason = book and book.block_reason or "conversion_failed"
    local text = {
        drm = _("This DRM-protected Kindle format is not supported."),
        missing_source = _("The source file is missing."),
        unsupported_format = _("This Kindle file format is not supported."),
        conversion_failed = _("Failed to prepare this book for reading."),
        drm_extractor_unavailable = _(
            "This Kindle firmware cannot extract this book's access key by itself. "
                .. "Install a compatible kfxdedrm native extractor, then reopen the book."
        ),
        drm_key_extraction_failed = _("Could not extract this book's access key. Check the KOReader debug log for details."),
        drm_after_key_extraction = _(
            "A book access key was extracted, but the book still could not be decrypted. "
                .. "Try re-downloading the book in the Kindle reader and opening it again."
        ),
    }
    return text[reason] or _("This book cannot be opened yet.")
end

function VirtualLibrary:isBookPrepared(book)
    if not book then
        return false
    end
    if book.open_mode == "direct" then
        return book.source_path ~= nil
    end
    if book.open_mode == "blocked" or not self.cache_manager or type(self.cache_manager.isFresh) ~= "function" then
        return false
    end
    local fresh = self.cache_manager:isFresh(book)
    return fresh == true
end

function VirtualLibrary:getUnpreparedBooks(force)
    local books, err = self:buildMappings(force)
    if not books then
        return nil, err
    end
    local unprepared = {}
    for _, book in ipairs(books) do
        if book.open_mode == "convert" and book.source_path and not self:isBookPrepared(book) then
            table.insert(unprepared, book)
        end
    end
    return unprepared
end

function VirtualLibrary:resolveBookPath(book)
    if not book then
        return nil, "missing book"
    end
    if book.open_mode == "blocked" then
        return nil, book.block_reason or "conversion_failed"
    end
    if book.open_mode == "direct" then
        return book.source_path
    end
    if not self.cache_manager or type(self.cache_manager.ensureCachedEpub) ~= "function" then
        return nil, "conversion_failed"
    end

    local cached_path, err = self.cache_manager:ensureCachedEpub(book)
    if cached_path then
        self.books_by_real_path[cached_path] = book
        return cached_path
    end
    return nil, err or "conversion_failed"
end

local function isValidThumbnail(path)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local attr = lfs.attributes(path)
    return attr and attr.mode == "file" and attr.size and attr.size >= 1024
end

function VirtualLibrary:getBookThumbnailPath(book)
    if not book then
        return nil
    end
    if book.resolved_thumbnail_path then
        return book.resolved_thumbnail_path
    end

    -- 1. Check book.thumbnail_path from cc.db
    if book.thumbnail_path then
        if isValidThumbnail(book.thumbnail_path) then
            book.resolved_thumbnail_path = book.thumbnail_path
            return book.thumbnail_path
        end
        -- Handle /mnt/us/ vs /mnt/base-us/ path differences on modern Kindles
        if book.thumbnail_path:sub(1, 8) == "/mnt/us/" then
            local alt = "/mnt/base-us/" .. book.thumbnail_path:sub(9)
            if isValidThumbnail(alt) then
                book.resolved_thumbnail_path = alt
                return alt
            end
        elseif book.thumbnail_path:sub(1, 13) == "/mnt/base-us/" then
            local alt = "/mnt/us/" .. book.thumbnail_path:sub(14)
            if isValidThumbnail(alt) then
                book.resolved_thumbnail_path = alt
                return alt
            end
        end
    end

    -- 2. Fallbacks for system/thumbnails/ and system/bookcovers/
    local prefixes = { "/mnt/us", "/mnt/base-us" }
    local keys = {}
    if book.cde_key and book.cde_key ~= "" then
        table.insert(keys, book.cde_key)
    end
    if book.uuid and book.uuid ~= "" then
        table.insert(keys, book.uuid)
    end
    if book.id and book.id:sub(1, 3) == "cc:" then
        table.insert(keys, book.id:sub(4))
    end

    for _, prefix in ipairs(prefixes) do
        for _, key in ipairs(keys) do
            local candidates = {
                prefix .. "/system/thumbnails/thumbnail_" .. key .. "_EBOK_portrait.jpg",
                prefix .. "/system/thumbnails/thumbnail_" .. key .. "_portrait.jpg",
                prefix .. "/system/thumbnails/thumbnail_" .. key .. "_PDOC_portrait.jpg",
            }
            for _, cand in ipairs(candidates) do
                if isValidThumbnail(cand) then
                    book.resolved_thumbnail_path = cand
                    return cand
                end
            end
        end

        local bookcovers_dir = prefix .. "/system/bookcovers"
        local battr = lfs.attributes(bookcovers_dir)
        if battr and battr.mode == "directory" then
            for entry in lfs.dir(bookcovers_dir) do
                if entry ~= "." and entry ~= ".." then
                    local sub = bookcovers_dir .. "/" .. entry
                    local sattr = lfs.attributes(sub)
                    if sattr and sattr.mode == "directory" then
                        for _, key in ipairs(keys) do
                            for f in lfs.dir(sub) do
                                if f:find(key, 1, true) and f:match("%.jpe?g$") then
                                    local match_path = sub .. "/" .. f
                                    if isValidThumbnail(match_path) then
                                        book.resolved_thumbnail_path = match_path
                                        return match_path
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return nil
end

function VirtualLibrary:createVirtualFolderEntry(parent_path)
    local entry = {
        text = self.VIRTUAL_LIBRARY_NAME .. "/",
        -- Keep a real filesystem path in the item. Selection is intercepted by
        -- FileChooserExt before normal directory navigation.
        path = parent_path or Device.home_dir or "/",
        attr = { mode = "directory" },
        is_kindle_library_folder = true,
        bidi_wrap_func = BD.directory,
    }
    if self.settings.virtual_library_cover_path and self.settings.virtual_library_cover_path ~= "" then
        entry.pt_cover_path = self.settings.virtual_library_cover_path
    end
    return entry
end

-- Real file (and attributes) a catalog row is listed at: the fresh cached
-- EPUB when one exists, else the Kindle source. Returns nil when neither
-- exists on disk; such books become unavailable action rows, not fake files.
local function resolveListedFile(vlib, book)
    if
        book.open_mode ~= "blocked"
        and book.open_mode ~= "direct"
        and vlib.cache_manager
        and type(vlib.cache_manager.getCachePaths) == "function"
        and vlib:isBookPrepared(book)
    then
        local cached_path = vlib.cache_manager:getCachePaths(book)
        local cached_attr = cached_path and lfs.attributes(cached_path) or nil
        if cached_attr and cached_attr.mode == "file" then
            return cached_path, cached_attr
        end
    end
    if book.source_path then
        local attr = lfs.attributes(book.source_path)
        if attr and attr.mode == "file" then
            return book.source_path, attr
        end
    end
    return nil
end

--- Native file rows plus generic action rows for cloud-only or lost books.
--- Row construction, collation and mandatory text stay native: no custom
--- author/status assembly, and listing never converts anything.
function VirtualLibrary:getBookEntries(file_chooser, force)
    local books, err = self:buildMappings(force)
    if not books then
        return nil, err
    end

    local files = {}
    local unavailable = {}
    local collate = file_chooser:getCollate()
    local source_filter
    for _, book in ipairs(books) do
        local title = sanitizeDisplayName(book.display_name or book.title or book.id)
        local list_path, attr = resolveListedFile(self, book)
        if not list_path then
            table.insert(unavailable, {
                text = title,
                path = file_chooser.path,
                kindle_book_id = book.id,
                kindle_unavailable = true,
                dim = true,
            })
        else
            local filter = file_chooser
            if list_path == book.source_path and book.open_mode == "convert" and isKindleSourcePath(list_path) then
                -- The catalog can prepare known Kindle sources even without a
                -- native provider. Retain the browser's other visibility rules.
                source_filter = source_filter or setmetatable({ show_unsupported = true }, { __index = file_chooser })
                filter = source_filter
            end
            local _, filename = util.splitFilePathName(list_path)
            if filter:show_file(filename, list_path) then
                local item = file_chooser:getListItem(nil, title, list_path, attr, collate)
                item.kindle_book_id = book.id
                table.insert(files, item)
            end
        end
    end
    return files, nil, unavailable
end

return VirtualLibrary
