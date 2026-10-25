-- Tests for KindleHomeDashboard module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("KindleHomeDashboard", function()
    local KindleHomeDashboard

    setup(function()
        helper.setup_complete()
        KindleHomeDashboard = require("lua/lib/kindle_home_dashboard")
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
end)
