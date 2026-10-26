local InfoMessage = require("ui/widget/infomessage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local KindleHighlightsViewer = {}
KindleHighlightsViewer.__index = KindleHighlightsViewer

function KindleHighlightsViewer:new(clippings_parser)
    local instance = {
        clippings_parser = clippings_parser,
    }
    setmetatable(instance, self)
    return instance
end

local function showInfo(text, timeout)
    UIManager:show(InfoMessage:new({ text = text, timeout = timeout or 4 }))
end

--- Export all clippings to a Markdown file.
--- @param by_book table
--- @param output_path string|nil
--- @return boolean, string
function KindleHighlightsViewer:exportToMarkdown(by_book, output_path)
    local path = output_path or "/mnt/us/documents/Kindle_Highlights.md"
    local file, err = io.open(path, "wb")
    if not file then
        return false, err or "failed to open output file"
    end

    file:write("# Kindle Highlights & Notes\n\n")
    file:write("*Exported on " .. os.date("%Y-%m-%d %H:%M:%S") .. "*\n\n---\n\n")

    -- Sort books by title
    local book_keys = {}
    for key in pairs(by_book) do
        table.insert(book_keys, key)
    end
    table.sort(book_keys)

    local total_highlights = 0
    for __, key in ipairs(book_keys) do
        local entry = by_book[key]
        local title = entry.title or "Untitled"
        local author = entry.author or ""
        local clippings = entry.clippings or {}

        file:write("## " .. title .. (author ~= "" and (" — *" .. author .. "*") or "") .. "\n\n")
        for __, clip in ipairs(clippings) do
            total_highlights = total_highlights + 1
            local loc_str = ""
            if clip.page then
                loc_str = "Page " .. clip.page
            end
            if clip.loc_start then
                if loc_str ~= "" then
                    loc_str = loc_str .. ", "
                end
                loc_str = loc_str .. "Location " .. clip.loc_start
                if clip.loc_end and clip.loc_end ~= clip.loc_start then
                    loc_str = loc_str .. "-" .. clip.loc_end
                end
            end
            if clip.added then
                if loc_str ~= "" then
                    loc_str = loc_str .. " • "
                end
                loc_str = loc_str .. clip.added
            end

            file:write("> " .. (clip.text or "") .. "\n\n")
            if loc_str ~= "" then
                file:write("*" .. loc_str .. "*\n\n")
            end
        end
        file:write("---\n\n")
    end

    file:close()
    logger.info("KindleHighlightsViewer: exported", total_highlights, "highlights to", path)
    return true, path
end

--- Show clippings for a specific book in a scrollable TextViewer.
--- @param entry table
function KindleHighlightsViewer:showBookClippings(entry)
    local lines = {}
    table.insert(lines, "# " .. entry.title .. (entry.author ~= "" and ("\nBy " .. entry.author) or ""))
    table.insert(lines, "\nTotal highlights: " .. #entry.clippings .. "\n")

    for i, clip in ipairs(entry.clippings) do
        local meta_parts = {}
        if clip.page then
            table.insert(meta_parts, "Page " .. clip.page)
        end
        if clip.loc_start then
            local loc = "Loc " .. clip.loc_start
            if clip.loc_end and clip.loc_end ~= clip.loc_start then
                loc = loc .. "-" .. clip.loc_end
            end
            table.insert(meta_parts, loc)
        end
        if clip.added then
            table.insert(meta_parts, clip.added)
        end

        table.insert(lines, "----------------------------------------")
        table.insert(lines, string.format("[%d] %s", i, table.concat(meta_parts, " | ")))
        table.insert(lines, clip.text)
        table.insert(lines, "")
    end

    local text = table.concat(lines, "\n")
    local viewer = TextViewer:new({
        title = entry.title,
        text = text,
    })
    UIManager:show(viewer)
end

--- Display the library-wide highlights browser dialog.
function KindleHighlightsViewer:show()
    local list, by_book = self.clippings_parser:parseFile(true)
    if not list or #list == 0 then
        showInfo(_("No Kindle clippings found in /mnt/us/documents/My Clippings.txt"))
        return false
    end

    -- Build menu entries for each book
    local items = {}
    local book_keys = {}
    for key in pairs(by_book) do
        table.insert(book_keys, key)
    end
    table.sort(book_keys)

    for __, key in ipairs(book_keys) do
        local entry = by_book[key]
        local title_display = entry.title
        if entry.author and entry.author ~= "" then
            title_display = title_display .. " (" .. entry.author .. ")"
        end
        local count_text = T(_("%1 highlights"), #entry.clippings)

        table.insert(items, {
            text = title_display,
            help_text = count_text,
            callback = function()
                self:showBookClippings(entry)
            end,
        })
    end

    -- Add Export button at top
    table.insert(items, 1, {
        text = T(_("--- Export all %1 highlights to Markdown ---"), #list),
        callback = function()
            local ok, result = self:exportToMarkdown(by_book)
            if ok then
                showInfo(T(_("Exported %1 highlights to:\n%2"), #list, result), 5)
            else
                showInfo(T(_("Export failed:\n%1"), result))
            end
        end,
    })

    local Menu = require("ui/widget/menu")

    local highlights_menu = Menu:new({
        title = T(_("Kindle Highlights (%1)"), #list),
        item_table = items,
        onMenuHold = function(self_menu, item)
            if item.callback then
                item.callback()
                return true
            end
        end,
    })

    UIManager:show(highlights_menu)
    return true
end

return KindleHighlightsViewer
