-- Tests for KindleCollectionsSync module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("KindleCollectionsSync", function()
    local KindleCollectionsSync
    local SQ3
    local CatalogDb

    setup(function()
        helper.setup_complete()
        KindleCollectionsSync = require("lua/lib/kindle_collections_sync")
        CatalogDb = require("lua/lib/kindle_catalog_db")
    end)

    before_each(function()
        helper.before_each()
        package.loaded["lua/lib/kindle_collections_sync"] = nil
        SQ3 = helper.install_sqlite_mock()
        CatalogDb._test_icu_installer = function()
            return true, function() end
        end
        KindleCollectionsSync = require("lua/lib/kindle_collections_sync")
    end)

    after_each(function()
        CatalogDb._test_icu_installer = nil
    end)

    it("parses collections and member book paths", function()
        SQ3._setMockResults({
            p_uuid = { "coll-1" },
            p_titles_0_nominal = { "Fantasy" },
        }, 1)

        local vlib = {
            getBook = function(_, id)
                if id == "cc:book-uuid-1" then
                    return { id = id, source_path = "/mnt/us/documents/book1.kfx" }
                end
            end,
        }

        local syncer = KindleCollectionsSync:new(vlib)
        local colls, err = syncer:getKindleCollections()

        assert.is_not_nil(colls)
        assert.is_nil(err)
        assert.equals(1, #colls)
        assert.equals("Fantasy", colls[1].name)
    end)
end)
