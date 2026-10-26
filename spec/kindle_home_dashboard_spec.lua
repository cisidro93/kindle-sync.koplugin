-- Tests for KindleHomeDashboard module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("KindleHomeDashboard", function()
    local KindleHomeDashboard
    local UIManager

    setup(function()
        helper.setup_complete()
        KindleHomeDashboard = require("lua/lib/kindle_home_dashboard")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        helper.before_each()
    end)

    it("initializes and reports whispersync status", function()
        local plugin = { last_whispersync_time = os.time() - 30 }
        local dashboard = KindleHomeDashboard:new(plugin)

        local status = dashboard:getWhispersyncStatusText()
        assert.is_not_nil(status)
        assert.is_truthy(status:match("now"))
    end)

    it("extracts last opened book info from settings", function()
        G_reader_settings:saveSetting("lastfile", "/mnt/us/documents/TestBook.epub")
        local dashboard = KindleHomeDashboard:new({})

        local book = dashboard:getLastOpenedBook()
        assert.is_not_nil(book)
        assert.equals("TestBook", book.title)
    end)

    it("renders showLibraryCatalog safely when book.authors is a table or string", function()
        local shown_widget
        local orig_show = UIManager.show
        UIManager.show = function(_, widget)
            shown_widget = widget
        end

        local dashboard = KindleHomeDashboard:new({})
        dashboard:showLibraryCatalog("Kindle Library", {
            {
                title = "Leviathan Wakes",
                authors = { "James S. A. Corey", "Daniel Abraham" },
                percent_finished = 42,
                source_path = "/mnt/us/documents/Leviathan.kfx",
            },
            {
                title = "Single Author String",
                authors = "Isaac Asimov",
                percent_finished = 0.75,
                source_path = "/mnt/us/documents/Foundation.kfx",
            },
        })

        UIManager.show = orig_show
        assert.is_not_nil(shown_widget)
        assert.equals(2, #shown_widget.item_table)
        assert.is_truthy(shown_widget.item_table[1].text:find("James S. A. Corey, Daniel Abraham", 1, true))
        assert.is_truthy(shown_widget.item_table[2].text:find("Isaac Asimov", 1, true))
    end)

    it("renders full-screen graphical KindleOS dashboard across tabs", function()
        local shown_widget
        local orig_show = UIManager.show
        local orig_close = UIManager.close
        UIManager.show = function(_, widget)
            shown_widget = widget
        end
        UIManager.close = function() end

        local vlib = {
            getOrderedBooks = function()
                return {
                    {
                        id = "cc:1",
                        title = "Project Hail Mary",
                        authors = { "Andy Weir" },
                        percent_finished = 65,
                        last_access = 1000,
                        source_path = "/mnt/us/documents/HailMary.kfx",
                    },
                }
            end,
        }
        local dashboard = KindleHomeDashboard:new({}, vlib)
        dashboard:show("home")
        assert.is_not_nil(shown_widget)
        assert.equals("kindle_os_dashboard", shown_widget.name)
        assert.is_true(shown_widget.covers_fullscreen)

        dashboard:switchTab("library")
        assert.equals("library", dashboard.current_tab)

        dashboard:switchTab("manga")
        assert.equals("manga", dashboard.current_tab)

        dashboard:switchTab("zlib")
        assert.equals("zlib", dashboard.current_tab)

        dashboard:switchTab("notes")
        assert.equals("notes", dashboard.current_tab)

        UIManager.show = orig_show
        UIManager.close = orig_close
    end)
end)
