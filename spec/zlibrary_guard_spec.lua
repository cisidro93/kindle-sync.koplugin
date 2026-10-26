-- Tests for ZlibraryGuard module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("ZlibraryGuard", function()
    local ZlibraryGuard
    local UIManager

    setup(function()
        helper.setup_complete()
        ZlibraryGuard = require("lua/lib/zlibrary_guard")
        UIManager = require("ui/uimanager")
    end)

    before_each(function()
        helper.before_each()
        package.loaded["zlibrary.ui"] = nil
        package.loaded["zlibrary.multisearch_dialog"] = nil
        package.loaded["zlibrary.download"] = nil
    end)

    it("normalizes titles and extracts core titles and author tokens", function()
        assert.equals("leviathan wakes", ZlibraryGuard.normalizeTitle("The Leviathan Wakes (The Expanse, Book 1)"))
        assert.equals("mindset", ZlibraryGuard.extractCoreTitle("Mindset: The New Psychology of Success (Updated Edition)"))
        local map, list = ZlibraryGuard.extractAuthorTokens({ "Carol S. Dweck", "John Doe" })
        assert.is_true(map["dweck"])
        assert.is_true(map["carol"])
        assert.is_true(#list >= 2)
    end)

    it("matches exact and subtitle-variant books against VirtualLibrary", function()
        local mock_vlib = {
            getOrderedBooks = function()
                return {
                    {
                        id = "cc:1",
                        title = "Mindset: The New Psychology of Success",
                        authors = { "Carol S. Dweck" },
                        percent_finished = 45,
                        source_path = "/mnt/us/documents/Mindset.kfx",
                    },
                    {
                        id = "cc:2",
                        title = "The Hunger Games",
                        authors = { "Suzanne Collins" },
                        percent_finished = 0,
                        source_path = "/mnt/us/documents/HungerGames.kfx",
                    },
                }
            end,
        }

        local guard = ZlibraryGuard:new(mock_vlib)

        local m1, t1 = guard:findMatch({
            title = "Mindset",
            author = "Dweck, Carol S.",
        })
        assert.is_not_nil(m1)
        assert.equals("exact", t1)
        assert.equals("cc:1", m1.id)

        local m2, t2 = guard:findMatch({
            title = "The Hunger Games (Book 1)",
            author = "Suzanne Collins",
        })
        assert.is_not_nil(m2)
        assert.equals("exact", t2)
        assert.equals("cc:2", m2.id)

        local m3, t3 = guard:findMatch({
            title = "Completely Unrelated Quantum Physics Book",
            author = "Richard Feynman",
        })
        assert.is_nil(m3)
        assert.is_nil(t3)
    end)

    it("hooks zlibrary.ui, zlibrary.multisearch_dialog, and zlibrary.download and unwinds cleanly", function()
        local mock_vlib = {
            getOrderedBooks = function()
                return {
                    {
                        id = "cc:1",
                        title = "Project Hail Mary",
                        authors = { "Andy Weir" },
                        percent_finished = 60,
                        source_path = "/mnt/us/documents/HailMary.kfx",
                    },
                }
            end,
        }

        local orig_create = function(book_data)
            return { text = book_data.title .. " by " .. (book_data.author or "") }
        end
        local orig_get_items = function(_, books)
            local out = {}
            for i, b in ipairs(books) do
                table.insert(out, { book_index = i, text = b.title })
            end
            return out
        end
        local download_called = 0
        local orig_run = function()
            download_called = download_called + 1
        end

        package.loaded["zlibrary.ui"] = {
            createBookMenuItem = orig_create,
        }
        package.loaded["zlibrary.multisearch_dialog"] = {
            _getMenuItems = orig_get_items,
        }
        package.loaded["zlibrary.download"] = {
            run = orig_run,
        }

        local guard = ZlibraryGuard:new(mock_vlib)
        assert.is_true(guard:installHooks())

        -- 1. Search result item gets badged
        local item = package.loaded["zlibrary.ui"].createBookMenuItem({
            title = "Project Hail Mary: A Novel",
            author = "Andy Weir",
        })
        assert.is_truthy(item.text:find("[✅ ON KINDLE • 60%]", 1, true))

        -- 2. MultiSearchDialog items get badged
        local msd_items = package.loaded["zlibrary.multisearch_dialog"]:_getMenuItems({
            { title = "Project Hail Mary", author = "Andy Weir" },
            { title = "New Unowned Book", author = "Someone Else" },
        })
        assert.is_truthy(msd_items[1].text:find("[✅ ON KINDLE • 60%]", 1, true))
        assert.is_falsy(msd_items[2].text:find("ON KINDLE", 1, true))

        -- 3. Download.run intercepts duplicate book and shows warning dialog instead of downloading
        local shown_dialog
        local orig_show = UIManager.show
        UIManager.show = function(_, widget)
            shown_dialog = widget
        end

        package.loaded["zlibrary.download"].run({}, {
            title = "Project Hail Mary",
            author = "Andy Weir",
        })
        UIManager.show = orig_show

        assert.equals(0, download_called)
        assert.is_not_nil(shown_dialog)

        -- 4. Unapply restores original functions
        guard:unapply()
        assert.equals(orig_create, package.loaded["zlibrary.ui"].createBookMenuItem)
        assert.equals(orig_get_items, package.loaded["zlibrary.multisearch_dialog"]._getMenuItems)
        assert.equals(orig_run, package.loaded["zlibrary.download"].run)
    end)
end)
