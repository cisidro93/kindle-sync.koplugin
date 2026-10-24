-- Tests for KindleHighlightImporter module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("KindleHighlightImporter", function()
    local KindleHighlightImporter

    setup(function()
        helper.setup_complete()
        KindleHighlightImporter = require("lua/lib/kindle_highlight_importer")
    end)

    before_each(function()
        helper.before_each()
    end)

    it("imports clippings into DocSettings bookmarks", function()
        local stored = {}
        local mock_doc_settings = {
            readSetting = function(_, key)
                return stored[key]
            end,
            saveSetting = function(_, key, val)
                stored[key] = val
            end,
        }

        local mock_parser = {
            getClippingsForBook = function(_, book)
                if book.title == "Mindset" then
                    return {
                        {
                            title = "Mindset",
                            type = "highlight",
                            page = 15,
                            loc_start = 299,
                            text = "First highlight text",
                            added = "2025-07-03 19:52:43",
                        },
                        {
                            title = "Mindset",
                            type = "highlight",
                            page = 16,
                            loc_start = 308,
                            text = "Second highlight text",
                            added = "2025-07-03 23:41:23",
                        },
                    }
                end
                return {}
            end,
        }

        local importer = KindleHighlightImporter:new(mock_parser)
        local count = importer:importHighlights({ title = "Mindset" }, mock_doc_settings)

        assert.equals(2, count)
        assert.is_true(stored["kindle_highlights_imported"])
        assert.equals(2, #stored["bookmarks"])
        assert.equals("First highlight text", stored["bookmarks"][1].text)
        assert.equals("Second highlight text", stored["bookmarks"][2].text)
        assert.is_true(stored["bookmarks"][1].kindle_imported)

        -- Second call without force should do nothing
        local count2 = importer:importHighlights({ title = "Mindset" }, mock_doc_settings)
        assert.equals(0, count2)
    end)

    it("avoids duplicate highlights when bookmarks already exist", function()
        local stored = {
            bookmarks = {
                {
                    text = "Existing highlight text",
                    page = 15,
                },
            },
        }
        local mock_doc_settings = {
            readSetting = function(_, key)
                return stored[key]
            end,
            saveSetting = function(_, key, val)
                stored[key] = val
            end,
        }

        local mock_parser = {
            getClippingsForBook = function()
                return {
                    {
                        title = "Mindset",
                        type = "highlight",
                        page = 15,
                        text = "Existing highlight text",
                    },
                    {
                        title = "Mindset",
                        type = "highlight",
                        page = 20,
                        text = "Brand new highlight text",
                    },
                }
            end,
        }

        local importer = KindleHighlightImporter:new(mock_parser)
        local count = importer:importHighlights({ title = "Mindset" }, mock_doc_settings, true)

        assert.equals(1, count)
        assert.equals(2, #stored["bookmarks"])
    end)
end)
