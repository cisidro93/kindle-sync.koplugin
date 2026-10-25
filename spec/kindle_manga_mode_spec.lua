-- Tests for KindleMangaMode module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("KindleMangaMode", function()
    local KindleMangaMode

    setup(function()
        helper.setup_complete()
        KindleMangaMode = require("lua/lib/kindle_manga_mode")
    end)

    before_each(function()
        helper.before_each()
    end)

    it("detects comics by file extension and keywords", function()
        local mode = KindleMangaMode:new({})
        assert.is_true(mode:isComicOrManga("/mnt/us/documents/OnePiece.cbz"))
        assert.is_true(mode:isComicOrManga("/mnt/us/documents/DC All In Saga.kfx"))
        assert.is_true(mode:isComicOrManga("/mnt/us/documents/AttackOnTitan_manga.epub"))
        assert.is_false(mode:isComicOrManga("/mnt/us/documents/TheExpanse.epub"))
    end)

    it("detects Japanese manga for RTL reading order", function()
        local mode = KindleMangaMode:new({})
        assert.is_true(mode:isRTLManga("/mnt/us/documents/Naruto_manga.cbz"))
        assert.is_true(mode:isRTLManga("/mnt/us/documents/Berserk [RTL].cbz"))
        assert.is_false(mode:isRTLManga("/mnt/us/documents/DC All In Saga.kfx"))
    end)

    it("configures reader on document open and cleans up on close", function()
        local saved = {}
        local ui = {
            document = { file = "/mnt/us/documents/test_manga.cbz" },
            doc_settings = {
                has = function(_, key)
                    return saved[key] ~= nil
                end,
                saveSetting = function(_, key, val)
                    saved[key] = val
                end,
                readSetting = function(_, key)
                    return saved[key]
                end,
            },
            paging = {},
        }

        local mode = KindleMangaMode:new({})
        mode:onDocumentOpen(ui)

        assert.is_true(mode.active)
        assert.is_true(mode.is_rtl)
        assert.equals("rtl", saved.page_turning_direction)

        mode:onDocumentClose()
        assert.is_false(mode.active)
    end)
end)
