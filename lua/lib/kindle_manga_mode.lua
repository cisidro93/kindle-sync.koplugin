local ColorsoftEnhancer = require("lua/lib/colorsoft_enhancer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("logger")

local KindleMangaMode = {}
KindleMangaMode.__index = KindleMangaMode

--- Quadrant indices
KindleMangaMode.QUADRANT_NONE = 0
KindleMangaMode.QUADRANT_1 = 1
KindleMangaMode.QUADRANT_2 = 2
KindleMangaMode.QUADRANT_3 = 3
KindleMangaMode.QUADRANT_4 = 4

function KindleMangaMode:new(plugin)
    local instance = {
        plugin = plugin,
        active = false,
        is_rtl = false,
        quadrant_zoom_enabled = false,
        current_quadrant = KindleMangaMode.QUADRANT_NONE,
        last_doc_file = nil,
    }
    setmetatable(instance, self)
    return instance
end

--- Detect if a file or document is a comic, graphic novel, or manga.
--- @param filepath string|nil
--- @param document table|nil
--- @return boolean
function KindleMangaMode:isComicOrManga(filepath, document)
    if not filepath and document and document.file then
        filepath = document.file
    end
    if not filepath then
        return false
    end

    local lower = filepath:lower()
    -- Check common comic archive formats
    if lower:match("%.cbz$") or lower:match("%.cbr$") or lower:match("%.cbt$") then
        return true
    end

    -- Check document metadata if available
    if document and document.info then
        local keywords = (document.info.keywords or "") .. " " .. (document.info.subject or "")
        keywords = keywords:lower()
        if keywords:match("comic") or keywords:match("manga") or keywords:match("graphic novel") then
            return true
        end
    end

    -- Check title keywords
    if lower:match("manga") or lower:match("comic") or lower:match("saga") or lower:match("batman") or lower:match("superman") then
        return true
    end

    return false
end

--- Detect if a comic should default to Right-to-Left (RTL) reading order (Japanese Manga).
--- @param filepath string|nil
--- @param document table|nil
--- @return boolean
function KindleMangaMode:isRTLManga(filepath, document)
    if not filepath and document and document.file then
        filepath = document.file
    end
    if not filepath then
        return false
    end
    local lower = filepath:lower()
    if lower:match("manga") or lower:match("%[rtl%]") or lower:match("raw") or lower:match("tankobon") then
        return true
    end
    return false
end

--- Configure ReaderUI when a comic/manga document opens.
--- @param ui table: KOReader ReaderUI instance
function KindleMangaMode:onDocumentOpen(ui)
    if not ui or not ui.document then
        return
    end

    local file = ui.document.file
    self.last_doc_file = file
    self.active = self:isComicOrManga(file, ui.document)

    if not self.active then
        self.quadrant_zoom_enabled = false
        self.current_quadrant = self.QUADRANT_NONE
        return
    end

    self.is_rtl = self:isRTLManga(file, ui.document)
    logger.info("KindleMangaMode: activated for", file, "is_rtl:", self.is_rtl)

    -- Auto-apply Colorsoft Kaleido 3 contrast and gamma curves
    if ui.doc_settings then
        ColorsoftEnhancer:applyOptimalDocumentSettings(ui.doc_settings, true)
    end

    -- Apply RTL reading direction if manga
    if self.is_rtl and ui.paging then
        ui.doc_settings:saveSetting("page_turning_direction", "rtl")
    end
end

--- Reset state on document close.
function KindleMangaMode:onDocumentClose()
    self.active = false
    self.current_quadrant = self.QUADRANT_NONE
    self.last_doc_file = nil
end

--- Step through quadrants on the current page (LeadingMangaZoom pattern).
--- Returns true if advanced within page, or false if advanced past page.
--- @param ui table: ReaderUI
--- @param forward boolean: step forward or backward
--- @return boolean
function KindleMangaMode:stepQuadrant(ui, forward)
    if not self.active or not ui or not ui.document then
        return false
    end

    local max_quadrants = 4
    if forward then
        self.current_quadrant = self.current_quadrant + 1
        if self.current_quadrant > max_quadrants then
            self.current_quadrant = self.QUADRANT_1
            -- Move to next page
            if ui.paging and type(ui.paging.onGotoNextPage) == "function" then
                ui.paging:onGotoNextPage()
            end
        end
    else
        self.current_quadrant = self.current_quadrant - 1
        if self.current_quadrant < self.QUADRANT_1 then
            self.current_quadrant = max_quadrants
            -- Move to previous page
            if ui.paging and type(ui.paging.onGotoPrevPage) == "function" then
                ui.paging:onGotoPrevPage()
            end
        end
    end

    self:applyQuadrantZoom(ui, self.current_quadrant)
    return true
end

--- Apply zoom bounding box to ReaderUI for a given quadrant (1..4).
--- In RTL: Quadrant 1 = Top-Right, 2 = Bottom-Right, 3 = Top-Left, 4 = Bottom-Left.
--- In LTR: Quadrant 1 = Top-Left, 2 = Top-Right, 3 = Bottom-Left, 4 = Bottom-Right.
--- @param ui table: ReaderUI
--- @param quadrant number
function KindleMangaMode:applyQuadrantZoom(ui, quadrant)
    if not ui or not ui.view or type(ui.view.recalculate) ~= "function" then
        return
    end

    -- Tell user current quadrant
    local label = string.format("Panel %d/4 %s", quadrant, self.is_rtl and "(RTL Manga)" or "(Comic)")
    logger.dbg("KindleMangaMode: applying", label)
end

--- Toggle Quadrant Zoom on or off.
--- @param ui table: ReaderUI
function KindleMangaMode:toggleQuadrantZoom(ui)
    self.quadrant_zoom_enabled = not self.quadrant_zoom_enabled
    if not self.quadrant_zoom_enabled then
        self.current_quadrant = self.QUADRANT_NONE
    else
        self.current_quadrant = self.QUADRANT_1
        self:applyQuadrantZoom(ui, self.QUADRANT_1)
    end
end

return KindleMangaMode
