local logger = require("logger")

local KindleHighlightImporter = {}
KindleHighlightImporter.__index = KindleHighlightImporter

function KindleHighlightImporter:new(clippings_parser)
    local instance = {
        clippings_parser = clippings_parser,
    }
    setmetatable(instance, self)
    return instance
end

--- Import Kindle highlights into a book's DocSettings bookmarks.
--- @param book table
--- @param doc_settings table: KOReader DocSettings instance
--- @param force boolean|nil: whether to re-import if already imported
--- @return number: count of newly imported bookmarks
function KindleHighlightImporter:importHighlights(book, doc_settings, force)
    if not book or not doc_settings or not self.clippings_parser then
        return 0
    end

    if not force and doc_settings:readSetting("kindle_highlights_imported") then
        return 0
    end

    local clippings = self.clippings_parser:getClippingsForBook(book)
    if not clippings or #clippings == 0 then
        doc_settings:saveSetting("kindle_highlights_imported", true)
        return 0
    end

    local existing_bookmarks = doc_settings:readSetting("bookmarks") or {}
    local existing_texts = {}
    for _, b in ipairs(existing_bookmarks) do
        if b.text and b.text ~= "" then
            existing_texts[b.text] = true
        end
    end

    local imported_count = 0
    for _, clip in ipairs(clippings) do
        if clip.text and clip.text ~= "" and not existing_texts[clip.text] then
            local bookmark = {
                datetime = clip.added or os.date("%Y-%m-%d %H:%M:%S"),
                text = clip.text,
                notes = "Kindle " .. clip.type:gsub("^%l", string.upper),
                page = clip.page or 1,
                highlighted = true,
                kindle_imported = true,
                kindle_location = clip.loc_start,
            }
            table.insert(existing_bookmarks, bookmark)
            existing_texts[clip.text] = true
            imported_count = imported_count + 1
        end
    end

    if imported_count > 0 then
        -- Sort bookmarks by page or location if available
        table.sort(existing_bookmarks, function(a, b)
            local loc_a = a.kindle_location or (a.page and a.page * 100) or 0
            local loc_b = b.kindle_location or (b.page and b.page * 100) or 0
            return loc_a < loc_b
        end)
        doc_settings:saveSetting("bookmarks", existing_bookmarks)
        logger.info("KindleHighlightImporter: imported", imported_count, "Kindle highlights for", book.id or book.title)
    end

    doc_settings:saveSetting("kindle_highlights_imported", true)
    return imported_count
end

return KindleHighlightImporter
