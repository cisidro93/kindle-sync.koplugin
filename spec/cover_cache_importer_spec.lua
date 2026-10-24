-- Tests for CoverCacheImporter module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("CoverCacheImporter", function()
    local CoverCacheImporter
    local SQ3
    local lfs
    local RenderImage
    local zstd

    local original_render_image
    local original_compress
    local original_uncompress

    setup(function()
        helper.setup_complete()
        CoverCacheImporter = require("lua/lib/cover_cache_importer")
        lfs = require("libs/libkoreader-lfs")
        RenderImage = require("ui/renderimage")
        zstd = require("ffi/zstd")

        original_render_image = RenderImage.renderImageFile
        original_compress = zstd.zstd_compress
        original_uncompress = zstd.zstd_uncompress_ctx
    end)

    before_each(function()
        helper.before_each()
        package.loaded["lua/lib/cover_cache_importer"] = nil
        SQ3 = helper.install_sqlite_mock()
        CoverCacheImporter = require("lua/lib/cover_cache_importer")
    end)

    after_each(function()
        RenderImage.renderImageFile = original_render_image
        zstd.zstd_compress = original_compress
        zstd.zstd_uncompress_ctx = original_uncompress
    end)

    describe("initialization", function()
        it("should create importer instance", function()
            local importer = CoverCacheImporter:new(nil, nil)
            assert.is_not_nil(importer)
            assert.is_truthy(importer:getDbPath():find("bookinfo_cache.sqlite3", 1, true))
        end)
    end)

    describe("importBookCover", function()
        it("should return false if book is missing", function()
            local importer = CoverCacheImporter:new(nil, nil)
            local ok, err = importer:importBookCover(nil)
            assert.is_false(ok)
            assert.equals("missing book", err)
        end)

        it("should return false if no thumbnail is found", function()
            local vlib = {
                getBookThumbnailPath = function()
                    return nil
                end,
            }
            local importer = CoverCacheImporter:new(vlib, nil)
            local ok, err = importer:importBookCover({ id = "cc:123" })
            assert.is_false(ok)
            assert.equals("no thumbnail found for book", err)
        end)

        it("should successfully import and cache a valid thumbnail", function()
            local vlib = {
                getBookThumbnailPath = function()
                    return "/mnt/us/system/thumbnails/thumb.jpg"
                end,
            }
            local cache_mgr = {
                getCachePaths = function(_, book)
                    return "/mnt/us/koreader/cache/" .. book.id .. ".epub"
                end,
            }

            local mock_bb = {
                w = 300,
                h = 400,
                stride = 300,
                data = "fake_image_bytes",
                getWidth = function()
                    return 300
                end,
                getHeight = function()
                    return 400
                end,
                getType = function()
                    return 0
                end,
                free = function() end,
            }

            RenderImage.renderImageFile = function()
                return mock_bb
            end

            zstd.zstd_compress = function()
                return "compressed_ptr", 100
            end

            lfs._setFileState("/mnt/us/koreader/settings/bookinfo_cache.sqlite3", {
                exists = true,
                attributes = { mode = "file", size = 1024 },
            })
            lfs._setFileState("/mnt/us/documents/book.kfx", {
                exists = true,
                attributes = { mode = "file", size = 5000 },
            })

            local importer = CoverCacheImporter:new(vlib, cache_mgr)
            importer.getDbPath = function()
                return "/mnt/us/koreader/settings/bookinfo_cache.sqlite3"
            end

            local ok, err = importer:importBookCover({
                id = "cc:123",
                title = "Test Book",
                authors = { "Author One" },
                source_path = "/mnt/us/documents/book.kfx",
            })

            assert.is_true(ok)
            assert.is_nil(err)
            assert.is_truthy(#SQ3._getMock().prepared_sql > 0)
        end)
    end)
end)
