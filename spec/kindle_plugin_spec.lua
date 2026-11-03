require("busted.runner")()
local helper = require("spec/test_helper")

--- Finds a menu entry by its visible text anywhere in the grouped menu.
local function findMenuItem(menu_items, text)
    local function search(items)
        for _, entry in ipairs(items or {}) do
            local label = entry.text
            if not label and entry.text_func then
                local ok, value = pcall(entry.text_func)
                label = ok and value or nil
            end
            if label == text then
                return entry
            end
            local children = entry.sub_item_table or (entry.sub_item_table_func and entry.sub_item_table_func())
            local found = children and search(children)
            if found then
                return found
            end
        end
    end
    return search(menu_items.kindle_plugin.sub_item_table)
end

describe("KindlePlugin", function()
    local LibraryIndex
    local VirtualLibrary
    local UIManager
    local instances
    local original_library_get_books
    local original_virtual_library_refresh

    setup(function()
        helper.setup_complete()
        UIManager = require("ui/uimanager")
        LibraryIndex = require("lua/library_index")
        VirtualLibrary = require("lua/virtual_library")
        original_library_get_books = LibraryIndex.getBooks
        original_virtual_library_refresh = VirtualLibrary.refresh
    end)

    before_each(function()
        helper.before_each()
        UIManager:_reset()
        package.loaded["main"] = nil
        instances = {}
    end)

    after_each(function()
        for _, instance in ipairs(instances) do
            pcall(function()
                instance:stopPlugin()
            end)
        end
        LibraryIndex.getBooks = original_library_get_books
        VirtualLibrary.refresh = original_virtual_library_refresh
    end)

    local function newPlugin(settings, ui)
        if settings then
            G_reader_settings:saveSetting("kindle_plugin", settings)
        end
        local KindlePlugin = require("main")
        local instance = KindlePlugin:new({
            ui = ui or {
                menu = { registerToMainMenu = function() end },
            },
        })
        table.insert(instances, instance)
        return instance
    end

    it("does not patch KOReader document/filesystem/reader APIs at module load", function()
        local lfs = require("libs/libkoreader-lfs")
        local DocumentRegistry = require("document/documentregistry")
        local ReaderUI = require("apps/reader/readerui")
        local attrs = lfs.attributes
        local open_document = DocumentRegistry.openDocument
        local show_reader = ReaderUI.showReader

        require("main")

        assert.equals(attrs, lfs.attributes)
        assert.equals(open_document, DocumentRegistry.openDocument)
        assert.equals(show_reader, ReaderUI.showReader)
    end)

    it("loads defaults while preserving explicit settings", function()
        local instance = newPlugin({
            enable_virtual_library = false,
            custom_setting = "preserved",
        })
        assert.is_false(instance.settings.enable_virtual_library)
        assert.equals("preserved", instance.settings.custom_setting)
        assert.is_not_nil(instance.settings.cache_dir)
    end)

    it("repairs the obsolete virtual HOME URI", function()
        G_reader_settings:saveSetting("home_dir", "KINDLE_VIRTUAL://")
        newPlugin({ enable_virtual_library = true })
        assert.not_equals("KINDLE_VIRTUAL://", G_reader_settings:readSetting("home_dir"))
    end)

    it("registers its menu and can be live-stopped", function()
        local registered = false
        local instance = newPlugin(nil, {
            menu = {
                registerToMainMenu = function()
                    registered = true
                end,
            },
        })
        assert.is_true(registered)
        assert.is_true(instance:stopPlugin())
    end)

    it("clears book keys only after confirmation", function()
        local cache_dir = os.tmpname()
        os.remove(cache_dir)
        assert.equals(0, os.execute("mkdir -p " .. cache_dir))
        local keys_path = cache_dir .. "/drm_keys.json"
        local keys_file = assert(io.open(keys_path, "wb"))
        keys_file:write("{}")
        keys_file:close()

        local instance = newPlugin({ cache_dir = cache_dir })
        local menu_item = instance:createClearKeysMenuItem()
        UIManager:_reset()
        menu_item.callback()

        local confirm = UIManager._shown_widgets[#UIManager._shown_widgets]
        assert.is_truthy(confirm)
        assert.is_function(confirm.ok_callback)
        confirm.ok_callback()

        assert.is_nil(io.open(keys_path, "rb"))
        local info = UIManager._shown_widgets[#UIManager._shown_widgets]
        assert.is_truthy(info.text:match("Book keys cleared"))
        os.execute("rm -rf " .. cache_dir)
    end)

    it("reports a book-key removal failure", function()
        local cache_dir = os.tmpname()
        os.remove(cache_dir)
        assert.equals(0, os.execute("mkdir -p " .. cache_dir))
        local keys_path = cache_dir .. "/drm_keys.json"
        local keys_file = assert(io.open(keys_path, "wb"))
        keys_file:write("{}")
        keys_file:close()

        local instance = newPlugin({ cache_dir = cache_dir })
        local menu_item = instance:createClearKeysMenuItem()
        UIManager:_reset()
        menu_item.callback()
        local confirm = UIManager._shown_widgets[#UIManager._shown_widgets]

        local original_remove = os.remove
        rawset(os, "remove", function(path)
            if path == keys_path then
                return nil, "permission denied"
            end
            return original_remove(path)
        end)
        confirm.ok_callback()
        rawset(os, "remove", original_remove)

        local still_there = assert(io.open(keys_path, "rb"))
        still_there:close()
        local info = UIManager._shown_widgets[#UIManager._shown_widgets]
        assert.is_truthy(info.text:match("Failed to clear book keys"))
        assert.is_truthy(info.text:match("permission denied"))
        os.execute("rm -rf " .. cache_dir)
    end)

    it("opens About Kindle Library without shadowing gettext", function()
        LibraryIndex.getBooks = function()
            return {
                { open_mode = "convert" },
                { open_mode = "direct" },
                { open_mode = "blocked" },
            }
        end

        local instance = newPlugin()
        UIManager:_reset()
        instance:createAboutMenuItem().callback()

        local info = UIManager._shown_widgets[#UIManager._shown_widgets]
        assert.is_truthy(info)
        assert.is_truthy(info.text:match("Kindle Virtual Library"))
        assert.is_truthy(info.text:match("Total books: 3"))
    end)

    it("refreshes the Kindle index without shadowing gettext", function()
        local instance = newPlugin()

        VirtualLibrary.refresh = function()
            return {}, nil
        end
        UIManager:_reset()
        instance:createRefreshLibraryMenuItem().callback()
        local info = UIManager._shown_widgets[#UIManager._shown_widgets]
        assert.is_truthy(info.text:match("Kindle library refreshed"))

        VirtualLibrary.refresh = function()
            return nil, "refresh failed"
        end
        UIManager:_reset()
        instance:createRefreshLibraryMenuItem().callback()
        info = UIManager._shown_widgets[#UIManager._shown_widgets]
        assert.is_truthy(info.text:match("Failed to refresh Kindle library"))
        assert.is_truthy(info.text:match("refresh failed"))
    end)

    it("keeps the menu available while the library view is disabled", function()
        local instance = newPlugin({ enable_virtual_library = false })
        instance.ui = { document = nil }
        local menu_items = {}
        instance:addToMainMenu(menu_items)
        assert.is_truthy(menu_items.kindle_plugin)
        assert.is_false(findMenuItem(menu_items, "Browse Kindle Library").enabled_func())
        assert.is_false(findMenuItem(menu_items, "Refresh Kindle Index").enabled_func())
    end)

    it("groups the menu with cross-device sync first", function()
        local instance = newPlugin()
        instance.ui = { document = nil }
        local menu_items = {}
        instance:addToMainMenu(menu_items)
        local top = menu_items.kindle_plugin.sub_item_table
        assert.are.equal("Cross-device sync", top[1].text)
        assert.is_true(#top <= 7)
        for _, title in ipairs({ "Pair this device…", "Sync this book now", "Disconnect this device" }) do
            assert.is_truthy(findMenuItem(menu_items, title), title)
        end
    end)

    it("keeps safe menu actions reachable inside ReaderUI and gates live-state hazards", function()
        local instance = newPlugin({ sync_reading_state = true }, {
            document = { file = "/tmp/book.epub" },
            doc_settings = {},
            menu = { registerToMainMenu = function() end },
        })
        local menu_items = {}
        instance:addToMainMenu(menu_items)
        assert.is_truthy(menu_items.kindle_plugin)
        local function item(text)
            return assert(findMenuItem(menu_items, text), text)
        end

        -- Browsing is safe because its handler performs normal ReaderUI
        -- teardown first. Read-only/index and settings actions stay available.
        assert.is_true(item("Browse Kindle Library").enabled_func())
        assert.is_true(item("Refresh Kindle Index").enabled_func())
        assert.is_nil(item("Clear Book Keys").enabled_func)
        assert.is_true(item("Sync reading state with Kindle").checked_func())
        assert.is_true(item("Sync behavior").enabled_func())

        -- These operate on persisted cache/DocSettings state and must not race
        -- the live document.
        assert.is_false(item("Clear Kindle Cache").enabled_func())
        assert.is_false(item("Sync all books now").enabled_func())
        assert.is_false(item("Sync current book now").enabled_func()) -- no session
        assert.is_false(item("Prepare all unprepared books").enabled_func()) -- doc open

        item("Browse Kindle Library").callback()
        local info = UIManager._shown_widgets[#UIManager._shown_widgets]
        assert.is_truthy(info.text:match("file browser"))
    end)

    it("does not arm an unreconciled close push when sync is enabled mid-book", function()
        local instance = newPlugin({ sync_reading_state = false }, {
            document = { file = "/tmp/book.epub" },
            doc_settings = {},
            menu = { registerToMainMenu = function() end },
        })

        instance:createSyncToggleMenuItem().callback()
        assert.is_true(instance.settings.sync_reading_state)
        assert.is_nil(instance._automatic_sync_open_document)

        instance:onCloseDocument()
        assert.is_nil(instance._pending_close_sync)
    end)

    it("syncs reading progress on suspend without discarding the open session", function()
        local flushed = false
        local synced = false
        local instance = newPlugin({
            sync_reading_state = true,
            sync_on_suspend = true,
            enable_auto_sync = true,
        }, {
            document = {
                file = "/tmp/book.epub",
                getXPointer = function()
                    return "/point"
                end,
            },
            rolling = {
                getLastPercent = function()
                    return 0.42
                end,
            },
            doc_settings = {
                data = {},
                readSetting = function()
                    return nil
                end,
                saveSetting = function() end,
                flush = function()
                    flushed = true
                end,
            },
            menu = { registerToMainMenu = function() end },
        })

        instance._automatic_sync_open_session = {
            cde_key = "B000000001",
            source_path = "/documents/book.kfx",
            epub_path = "/tmp/book.epub",
        }

        package.loaded["lua/reading_state_sync"].syncToKindleAutomatic = function()
            synced = true
            return true
        end

        instance:onSuspend()
        assert.is_true(flushed)
        assert.is_true(synced)
        -- Session remains armed for subsequent reads and close
        assert.is_not_nil(instance._automatic_sync_open_session)
    end)

    it("allows manual sync of current open book", function()
        local flushed = false
        local synced = false
        local instance = newPlugin({
            sync_reading_state = true,
            enable_auto_sync = true,
        }, {
            document = {
                file = "/tmp/book.epub",
                getXPointer = function()
                    return "/point"
                end,
            },
            rolling = {
                getLastPercent = function()
                    return 0.75
                end,
            },
            doc_settings = {
                data = {},
                readSetting = function()
                    return nil
                end,
                saveSetting = function() end,
                flush = function()
                    flushed = true
                end,
            },
            menu = { registerToMainMenu = function() end },
        })

        instance._automatic_sync_open_session = {
            cde_key = "B000000001",
            source_path = "/documents/book.kfx",
            epub_path = "/tmp/book.epub",
        }

        package.loaded["lua/reading_state_sync"].syncToKindleAutomatic = function()
            synced = true
            return true
        end

        local item = instance:createSyncCurrentBookMenuItem()
        assert.is_true(item.enabled_func())
        item.callback()
        assert.is_true(flushed)
        assert.is_true(synced)
    end)
end)
