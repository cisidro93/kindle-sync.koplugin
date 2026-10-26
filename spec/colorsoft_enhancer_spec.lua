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
end)
