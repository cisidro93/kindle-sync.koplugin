local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local KindleHomeDashboard = {}
KindleHomeDashboard.__index = KindleHomeDashboard

function KindleHomeDashboard:new(
    plugin,
    virtual_library,
    kindle_library,
    goal_tracker,
    collections_sync,
    highlights_viewer,
    manga_mode,
    zlibrary_guard
)
    local instance = {
        plugin = plugin,
        virtual_library = virtual_library,
        kindle_library = kindle_library,
        goal_tracker = goal_tracker,
        collections_sync = collections_sync,
        highlights_viewer = highlights_viewer,
        manga_mode = manga_mode,
        zlibrary_guard = zlibrary_guard,
        active_menu = nil,
    }
    setmetatable(instance, self)
    return instance
end

local function showInfo(text, timeout)
    UIManager:show(InfoMessage:new({ text = text, timeout = timeout or 3 }))
end

local function safeCallback(label, fn)
    return function()
        local ok, err = pcall(fn)
        if not ok then
            logger.warn("KindleHomeDashboard:", label, "failed:", err)
            showInfo(T(_("Action failed:\n%1"), tostring(err)), 4)
        end
    end
end

local function formatAuthors(authors)
    if type(authors) == "table" then
        local parts = {}
        for __, a in ipairs(authors) do
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

--- Get summary text for Whispersync status.
--- @return string
function KindleHomeDashboard:getWhispersyncStatusText()
    local last_time = self.plugin and self.plugin.last_whispersync_time
    if last_time then
        local elapsed = os.time() - last_time
        local mins = math.floor(elapsed / 60)
        if mins < 1 then
            return _("Synced just now")
        elseif mins == 1 then
            return _("Synced 1 min ago")
        else
            return T(_("Synced %1 mins ago"), mins)
        end
    end
    return _("Connected • Tap to sync")
end

--- Get last opened book info.
--- @return table|nil
function KindleHomeDashboard:getLastOpenedBook()
    local lastfile = G_reader_settings:readSetting("lastfile")
    if not lastfile or lastfile == "" then
        return nil
    end

    if self.virtual_library then
        local ok, book = pcall(self.virtual_library.getBook, self.virtual_library, lastfile)
        if ok and book then
            return book
        end
    end

    local title = lastfile:match("([^/]+)%.%w+$") or lastfile
    return {
        title = title,
        source_path = lastfile,
    }
end

--- Launch and show the primary KindleOS Home Dashboard.
function KindleHomeDashboard:show()
    local goal_data = {}
    if self.goal_tracker and type(self.goal_tracker.getData) == "function" then
        local ok, res = pcall(self.goal_tracker.getData, self.goal_tracker)
        if ok and type(res) == "table" then
            goal_data = res
        end
    end
    local streak = goal_data.streak_days or 0
    local streak_str = streak > 0 and (tostring(streak) .. "-day streak 🔥") or "No active streak"
    local today_mins = goal_data.today_minutes or 0
    local target_mins = goal_data.target_minutes or 30

    local last_book = self:getLastOpenedBook()
    local items = {}

    -- 1. Hero: Currently Reading / Continue Reading
    if last_book and last_book.title then
        table.insert(items, {
            text = T(_("▶ Continue Reading: %1"), last_book.title),
            help_text = _("Resume your last reading session."),
            bold = true,
            callback = safeCallback("Continue Reading", function()
                if self.active_menu then
                    UIManager:close(self.active_menu)
                end
                local open_path = last_book.source_path or last_book.cached_path
                if open_path then
                    local ui = (self.kindle_library and self.kindle_library.ui) or (self.plugin and self.plugin.ui)
                    if ui then
                        require("apps/filemanager/filemanagerutil").openFile(ui, open_path)
                    else
                        require("apps/filemanager/filemanagerutil").openFile(open_path)
                    end
                end
            end),
        })
    end

    -- 2. Daily Goal & Streak status item
    table.insert(items, {
        text = T(_("🔥 Reading Goal: %1/%2 mins (%3)"), today_mins, target_mins, streak_str),
        help_text = _("Tap to view your daily reading goals and streak dashboard."),
        callback = safeCallback("Reading Goal", function()
            if self.goal_tracker then
                self.goal_tracker:showDashboard()
            end
        end),
    })

    -- 3. Kindle Library Browser (All Books)
    local all_books = {}
    if self.virtual_library then
        if type(self.virtual_library.getOrderedBooks) == "function" then
            local ok, res = pcall(self.virtual_library.getOrderedBooks, self.virtual_library)
            if ok and type(res) == "table" then
                all_books = res
            end
        elseif type(self.virtual_library.buildMappings) == "function" then
            local ok, res = pcall(self.virtual_library.buildMappings, self.virtual_library, false)
            if ok and type(res) == "table" then
                all_books = res
            end
        end
    end
    table.insert(items, {
        text = T(_("📚 Kindle Library (%1 books)"), #all_books),
        help_text = _("Browse all your Kindle books with high-resolution covers and progress."),
        callback = safeCallback("Kindle Library", function()
            local ui = (self.kindle_library and self.kindle_library.ui) or (self.plugin and self.plugin.ui)
            if self.kindle_library and ui and ui.file_chooser and type(self.kindle_library.show) == "function" then
                if self.active_menu then
                    UIManager:close(self.active_menu)
                end
                if self.kindle_library:show(ui, false) then
                    return
                end
            end
            self:showLibraryCatalog(_("Kindle Library"), all_books)
        end),
    })
    table.insert(items, {
        text = T(_("📋 Quick Book List (%1 books)"), #all_books),
        help_text = _("Fast text list of all Kindle books with progress and comic badges."),
        callback = safeCallback("Quick Book List", function()
            self:showLibraryCatalog(_("Kindle Library"), all_books)
        end),
    })

    -- 4. Z-Library Search with Dedupe Guard
    local guard = self.zlibrary_guard or (self.plugin and self.plugin.zlibrary_guard)
    if guard then
        table.insert(items, {
            text = _("🔍 Search Kindle & Z-Library (Dedupe Guard)"),
            help_text = _("Check if a book is already on your Kindle before searching or downloading from Z-Library."),
            callback = safeCallback("Z-Library Dedupe Guard", function()
                guard:showLibraryCheckDialog()
            end),
        })
    end

    -- 5. Comics & Manga Hub
    local comic_books = {}
    for __, book in ipairs(all_books) do
        if self.manga_mode and self.manga_mode:isComicOrManga(book.source_path) then
            table.insert(comic_books, book)
        end
    end
    table.insert(items, {
        text = T(_("🎨 Comics & Manga (%1)"), #comic_books),
        help_text = _("Graphic novels and manga with automatic RTL navigation and panel zoom."),
        callback = safeCallback("Comics & Manga", function()
            self:showLibraryCatalog(_("Comics & Manga"), comic_books)
        end),
    })

    -- 6. Amazon Collections
    table.insert(items, {
        text = _("📁 Amazon Collections"),
        help_text = _("Browse your books organized by Amazon collections."),
        callback = safeCallback("Amazon Collections", function()
            self:showCollectionsMenu()
        end),
    })

    -- 7. Kindle Highlights & Annotations
    table.insert(items, {
        text = _("📝 Kindle Highlights & Notes"),
        help_text = _("View and export your clippings and highlights to Markdown."),
        callback = safeCallback("Kindle Highlights", function()
            if self.highlights_viewer then
                self.highlights_viewer:show()
            end
        end),
    })

    -- 8. Whispersync cloud sync button
    local ws_status = self:getWhispersyncStatusText()
    table.insert(items, {
        text = T(_("☁️ Whispersync: %1"), ws_status),
        help_text = _("Triggers an immediate Amazon cloud sync for reading positions and streaks."),
        callback = safeCallback("Whispersync", function()
            if self.plugin and type(self.plugin.triggerKindleCloudSync) == "function" then
                self.plugin:triggerKindleCloudSync()
                self.plugin.last_whispersync_time = os.time()
                showInfo(_("Whispersync cloud sync triggered with Amazon."))
                if self.active_menu then
                    UIManager:close(self.active_menu)
                    self:show()
                end
            end
        end),
    })

    -- 9. Cache all covers
    table.insert(items, {
        text = _("🖼️ Cache All Kindle Covers (Instant)"),
        help_text = _("Extracts pre-rendered 300x400 covers from Kindle storage in ~4 seconds."),
        callback = safeCallback("Cache Covers", function()
            if self.kindle_library and type(self.kindle_library.extractAllCovers) == "function" then
                local count = self.kindle_library:extractAllCovers()
                showInfo(T(_("Successfully cached %1 covers!"), count))
            end
        end),
    })

    -- 10. Sideloaded File Browser fallback
    table.insert(items, {
        text = _("📂 KOReader File Browser"),
        help_text = _("Switch to KOReader's classic file manager for sideloaded documents."),
        callback = safeCallback("File Browser", function()
            if self.active_menu then
                UIManager:close(self.active_menu)
            end
        end),
    })

    local title_str = _("KindleOS • Colorsoft Edition")
    if Device and Device.model then
        title_str = string.format("KindleOS • %s", Device.model)
    end

    self.active_menu = Menu:new({
        title = title_str,
        item_table = items,
    })

    UIManager:show(self.active_menu)
end

--- Show a paginated book catalog for a given list of books.
--- @param title string
--- @param book_list table
function KindleHomeDashboard:showLibraryCatalog(title, book_list)
    local items = {}
    local catalog_menu

    for __, book in ipairs(book_list) do
        local book_title = tostring(book.title or _("Untitled"))
        local authors_str = formatAuthors(book.authors or book.author)
        local author = authors_str ~= "" and (" — " .. authors_str) or ""
        local pct = tonumber(book.percent_finished)
        local percent = _("Unread")
        if pct and pct > 0 then
            percent = string.format("%d%%", pct <= 1 and math.floor(pct * 100) or math.floor(pct))
        end
        local is_comic = self.manga_mode and self.manga_mode:isComicOrManga(book.source_path)
        local badge = is_comic and " [Comic]" or ""

        table.insert(items, {
            text = book_title .. badge .. author,
            help_text = T(_("Progress: %1 • Path: %2"), percent, book.source_path or ""),
            callback = safeCallback("Open Catalog Book", function()
                if catalog_menu then
                    UIManager:close(catalog_menu)
                end
                if self.active_menu then
                    UIManager:close(self.active_menu)
                end
                local open_path = book.source_path
                if self.virtual_library and self.virtual_library.cache_manager then
                    local cached = self.virtual_library.cache_manager:getCachePaths(book)
                    if cached and self.virtual_library:isBookPrepared(book) then
                        open_path = cached
                    end
                end
                if open_path then
                    local ui = (self.kindle_library and self.kindle_library.ui) or (self.plugin and self.plugin.ui)
                    if ui then
                        require("apps/filemanager/filemanagerutil").openFile(ui, open_path)
                    else
                        require("apps/filemanager/filemanagerutil").openFile(open_path)
                    end
                end
            end),
        })
    end

    if #items == 0 then
        table.insert(items, {
            text = _("No books found in this category."),
            callback = function() end,
        })
    end

    catalog_menu = Menu:new({
        title = T(_("%1 (%2)"), title, #book_list),
        item_table = items,
    })

    UIManager:show(catalog_menu)
end

--- Show collections menu.
function KindleHomeDashboard:showCollectionsMenu()
    if not self.collections_sync then
        showInfo(_("Collections sync not initialized."))
        return
    end

    local collections, err = self.collections_sync:getKindleCollections()
    if not collections or #collections == 0 then
        showInfo(err or _("No Kindle collections found in cc.db."))
        return
    end

    local items = {}
    for __, coll in ipairs(collections) do
        local count = coll.books and #coll.books or 0
        table.insert(items, {
            text = T(_("📁 %1 (%2 books)"), coll.name, count),
            callback = safeCallback("Open Collection", function()
                local books = {}
                for __idx, path in ipairs(coll.books) do
                    local b = self.virtual_library and self.virtual_library:getBook(path)
                    table.insert(books, b or { title = path:match("([^/]+)$"), source_path = path })
                end
                self:showLibraryCatalog(coll.name, books)
            end),
        })
    end

    local coll_menu = Menu:new({
        title = T(_("Amazon Collections (%1)"), #collections),
        item_table = items,
    })

    UIManager:show(coll_menu)
end

return KindleHomeDashboard
