local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local ffi = require("ffi")

local ColorsoftEnhancer = {
    DEFAULT_SATURATION = 1.28, -- +28% color vibrance for Kaleido 3 CFA
    DEFAULT_GAMMA = 0.88, -- Counteract Kaleido 3 CFA light absorption
    DEFAULT_CONTRAST = 1.15, -- Deepen blacks on color e-paper
}

--- Check if the current device is a Kindle Colorsoft (or color e-ink device).
--- @return boolean
function ColorsoftEnhancer:isColorsoftDevice()
    if Device and (Device:hasColorScreen() or Device.isColorsoft or Device.model == "Kindle Colorsoft") then
        return true
    end
    -- Also detect if color_rendering is enabled in global settings
    if G_reader_settings and G_reader_settings:isTrue("color_rendering") then
        return true
    end
    return false
end

--- Apply real-time color vibrance and contrast curve to a 32-bit RGBA BlitBuffer.
--- Specially tuned for Kaleido 3 displays which absorb ~30% of reflected light.
--- @param bb table: Blitbuffer
--- @param saturation number|nil: Vibrance factor (default 1.28)
--- @param contrast number|nil: Contrast factor (default 1.15)
function ColorsoftEnhancer:enhanceBlitBuffer(bb, saturation, contrast)
    if not bb or type(bb.getType) ~= "function" or bb:getType() ~= Blitbuffer.TYPE_BBRGBA_32 then
        return false
    end

    local sat = saturation or self.DEFAULT_SATURATION
    local con = contrast or self.DEFAULT_CONTRAST
    local w = bb.w
    local h = bb.h
    local stride = tonumber(bb.stride)
    local ok, data_ptr = pcall(ffi.cast, "uint8_t*", bb.data)
    if not ok or not data_ptr then
        return false
    end

    -- Midpoint for contrast adjustment (128 on 0-255 scale)
    local mid = 128.0

    for y = 0, h - 1 do
        local row_offset = y * stride
        for x = 0, w - 1 do
            local idx = row_offset + x * 4
            local r = data_ptr[idx]
            local g = data_ptr[idx + 1]
            local b = data_ptr[idx + 2]

            -- 1. Vibrance (saturation) boost
            local lum = 0.299 * r + 0.587 * g + 0.114 * b
            local nr = lum + (r - lum) * sat
            local ng = lum + (g - lum) * sat
            local nb = lum + (b - lum) * sat

            -- 2. Contrast boost (deepen blacks, highlight whites)
            nr = mid + (nr - mid) * con
            ng = mid + (ng - mid) * con
            nb = mid + (nb - mid) * con

            -- Clamp to 0..255
            data_ptr[idx] = nr < 0 and 0 or (nr > 255 and 255 or nr)
            data_ptr[idx + 1] = ng < 0 and 0 or (ng > 255 and 255 or ng)
            data_ptr[idx + 2] = nb < 0 and 0 or (nb > 255 and 255 or nb)
        end
    end

    return true
end

--- Apply optimal display settings for a comic/manga document in KOReader.
--- @param doc_settings table: KOReader DocSettings instance
--- @param is_comic boolean|nil: whether document is fixed-layout comic/manga
function ColorsoftEnhancer:applyOptimalDocumentSettings(doc_settings, is_comic)
    if not doc_settings or type(doc_settings.readSetting) ~= "function" then
        return
    end

    -- Ensure color rendering is enabled
    if not doc_settings:has("color_rendering") then
        doc_settings:saveSetting("color_rendering", true)
    end

    if is_comic then
        -- Fit full page for comics & manga
        if not doc_settings:has("zoom_mode") then
            doc_settings:saveSetting("zoom_mode", "content")
        end
        -- Gamma curve to brighten comic midtones
        if not doc_settings:has("copt_font_gamma") then
            doc_settings:saveSetting("copt_font_gamma", 20)
        end
        -- Deepen black ink lines in comic scans
        if not doc_settings:has("contrast") then
            doc_settings:saveSetting("contrast", 1.15)
        end
    end
end

--- Get recommended gamma value for Kindle Colorsoft.
--- @return number
function ColorsoftEnhancer:getRecommendedGamma()
    return self.DEFAULT_GAMMA
end

return ColorsoftEnhancer
