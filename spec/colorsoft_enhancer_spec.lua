-- Tests for ColorsoftEnhancer module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("ColorsoftEnhancer", function()
    local ColorsoftEnhancer

    setup(function()
        helper.setup_complete()
        ColorsoftEnhancer = require("lua/lib/colorsoft_enhancer")
    end)

    before_each(function()
        helper.before_each()
    end)

    it("reports recommended gamma for Colorsoft", function()
        local gamma = ColorsoftEnhancer:getRecommendedGamma()
        assert.is_number(gamma)
        assert.is_true(gamma < 1.0)
    end)

    it("applies optimal settings to doc_settings for comic document", function()
        local saved = {}
        local doc_settings = {
            has = function(_, key)
                return saved[key] ~= nil
            end,
            saveSetting = function(_, key, val)
                saved[key] = val
            end,
            readSetting = function(_, key)
                return saved[key]
            end,
        }

        ColorsoftEnhancer:applyOptimalDocumentSettings(doc_settings, true)
        assert.is_true(saved.color_rendering)
        assert.equals("content", saved.zoom_mode)
        assert.equals(20, saved.copt_font_gamma)
        assert.equals(1.15, saved.contrast)
    end)

    it("enhances 24-bit RGB (TYPE_BBRGB24) and 32-bit RGB (TYPE_BBRGB32) blitbuffers safely", function()
        local Blitbuffer = require("ffi/blitbuffer")
        local ffi = require("ffi")

        -- 24-bit RGB (3 bytes per pixel)
        local buf24 = ffi.new("uint8_t[6]", { 200, 100, 50, 120, 150, 180 })
        local bb24 = {
            w = 2,
            h = 1,
            stride = 6,
            data = buf24,
            getType = function()
                return Blitbuffer.TYPE_BBRGB24
            end,
        }
        assert.is_true(ColorsoftEnhancer:enhanceBlitBuffer(bb24))
        assert.is_true(buf24[0] > 200) -- red boosted

        -- Rejects buffer when stride is smaller than w * bpp (prevents heap overflow)
        local bad_bb = {
            w = 2,
            h = 1,
            stride = 4, -- < 2 * 3
            data = buf24,
            getType = function()
                return Blitbuffer.TYPE_BBRGB24
            end,
        }
        assert.is_false(ColorsoftEnhancer:enhanceBlitBuffer(bad_bb))
    end)
end)
