local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local KindleClippingsParser = {}
KindleClippingsParser.__index = KindleClippingsParser

KindleClippingsParser.DEFAULT_CLIPPINGS_PATHS = {
    "/mnt/us/documents/My Clippings.txt",
    "/mnt/base-us/documents/My Clippings.txt",
}

function KindleClippingsParser:new(custom_path)
    local instance = {
        custom_path = custom_path,
        cached_clippings = nil,
    }
    setmetatable(instance, self)
    return instance
end

--- Find the active My Clippings.txt path on disk.
--- @return string|nil
function KindleClippingsParser:findClippingsPath()
    if self.custom_path then
        local attr = lfs.attributes(self.custom_path)
        if attr and attr.mode == "file" and attr.size and attr.size > 0 then
            return self.custom_path
        end
    end

    for _, path in ipairs(self.DEFAULT_CLIPPINGS_PATHS) do
        local attr = lfs.attributes(path)
        if attr and attr.mode == "file" and attr.size and attr.size > 0 then
            return path
        end
    end
    return nil
end

--- Parse title and author from line 1: "Title of Book (Author Name)"
--- @param line string
--- @return string: title
--- @return string: author
local function parseTitleAuthor(line)
    local title = line or ""
    local author = ""

    local clean = title:gsub("[\r\n]+", ""):gsub("^%s+", ""):gsub("%s+$", "")
    -- Strip UTF-8 BOM if present
    if clean:sub(1, 3) == "\xEF\xBB\xBF" then
        clean = clean:sub(4)
    end

    -- Match "Title (Author)" at end of string
    local t, a = clean:match("^(.-)%s*%(([^%(%)]+)%)%s*$")
    if t and a then
        return t:gsub("^%s+", ""):gsub("%s+$", ""), a:gsub("^%s+", ""):gsub("%s+$", "")
    end

    return clean, author
end

--- Parse metadata line: "- Your Highlight on page 15 | Location 299-299 | Added on Thursday, July 3, 2025"
--- @param line string
--- @return table
local function parseMetaLine(line)
    local meta = {
        type = "highlight",
        page = nil,
        loc_start = nil,
        loc_end = nil,
        added = nil,
    }

    if not line then
        return meta
    end

    local clean = line:gsub("[\r\n]+", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean:match("Your Note") then
        meta.type = "note"
    elseif clean:match("Your Bookmark") then
        meta.type = "bookmark"
    else
        meta.type = "highlight"
    end

    -- Extract page
    local page_str = clean:match("page%s+(%d+)")
    if page_str then
        meta.page = tonumber(page_str)
    end

    -- Extract location
    local loc_s, loc_e = clean:match("Location%s+(%d+)%-(%d+)")
    if loc_s and loc_e then
        meta.loc_start = tonumber(loc_s)
        meta.loc_end = tonumber(loc_e)
    else
        local single_loc = clean:match("Location%s+(%d+)")
        if single_loc then
            meta.loc_start = tonumber(single_loc)
            meta.loc_end = tonumber(single_loc)
        end
    end

    -- Extract Added date
    local added = clean:match("Added on%s+(.-)$")
    if added then
        meta.added = added:gsub("^%s+", ""):gsub("%s+$", "")
    end

    return meta
end

--- Parse raw text of My Clippings.txt into structured records.
--- @param content string
--- @return table: list of all clippings
--- @return table: clippings grouped by normalized book title
function KindleClippingsParser.parseContent(content)
    if not content or content == "" then
        return {}, {}
    end

    local list = {}
    local by_book = {}

    -- Normalize newlines
    local normalized = content:gsub("\r\n", "\n"):gsub("\r", "\n")
    -- Split by delimiter
    local entries = {}
    local current_entry = {}

    for line in normalized:gmatch("([^\n]*)\n?") do
        if line:match("^==========") then
            if #current_entry > 0 then
                table.insert(entries, current_entry)
                current_entry = {}
            end
        else
            table.insert(current_entry, line)
        end
    end
    if #current_entry > 0 then
        table.insert(entries, current_entry)
    end

    for _, entry_lines in ipairs(entries) do
        -- Entry format:
        -- line 1: Title (Author)
        -- line 2: - Your Highlight on...
        -- line 3+: highlight text
        if #entry_lines >= 2 then
            local title_line = entry_lines[1]
            local meta_line = entry_lines[2]

            local title, author = parseTitleAuthor(title_line)
            local meta = parseMetaLine(meta_line)

            -- Collect remaining non-empty lines as text
            local text_parts = {}
            for i = 3, #entry_lines do
                local l = entry_lines[i]:gsub("^%s+", ""):gsub("%s+$", "")
                if l ~= "" then
                    table.insert(text_parts, l)
                end
            end
            local text = table.concat(text_parts, " ")

            if title ~= "" and (text ~= "" or meta.type == "bookmark") then
                local item = {
                    title = title,
                    author = author,
                    type = meta.type,
                    page = meta.page,
                    loc_start = meta.loc_start,
                    loc_end = meta.loc_end,
                    added = meta.added,
                    text = text,
                }
                table.insert(list, item)

                local norm_title = title:lower():gsub("[^%w%s]", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
                if not by_book[norm_title] then
                    by_book[norm_title] = {
                        title = title,
                        author = author,
                        clippings = {},
                    }
                end
                table.insert(by_book[norm_title].clippings, item)
            end
        end
    end

    return list, by_book
end

--- Parse the clippings file from disk.
--- @param force boolean|nil
--- @return table|nil: list of clippings
--- @return table|nil: grouped by book
--- @return string|nil: error message
function KindleClippingsParser:parseFile(force)
    if self.cached_clippings and not force then
        return self.cached_clippings.list, self.cached_clippings.by_book
    end

    local path = self:findClippingsPath()
    if not path then
        return nil, nil, "My Clippings.txt not found"
    end

    local file = io.open(path, "rb")
    if not file then
        return nil, nil, "cannot read " .. path
    end

    local content = file:read("*a")
    file:close()

    local list, by_book = self.parseContent(content)
    self.cached_clippings = {
        path = path,
        list = list,
        by_book = by_book,
        mtime = lfs.attributes(path, "modification"),
    }

    logger.info("KindleClippingsParser: parsed", #list, "clippings across", util.tableSize(by_book), "books from", path)
    return list, by_book
end

--- Get clippings for a specific book.
--- @param book table
--- @return table
function KindleClippingsParser:getClippingsForBook(book)
    if not book then
        return {}
    end

    local _, by_book = self:parseFile(false)
    if not by_book then
        return {}
    end

    local candidates = {
        book.title,
        book.display_name,
    }

    for _, cand in ipairs(candidates) do
        if cand and cand ~= "" then
            local norm = cand:lower():gsub("[^%w%s]", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
            if by_book[norm] then
                return by_book[norm].clippings or {}
            end
            -- Substring match (e.g. "Mindset: The New Psychology of Success" vs "Mindset")
            for norm_key, entry in pairs(by_book) do
                if norm_key:find(norm, 1, true) or norm:find(norm_key, 1, true) then
                    return entry.clippings or {}
                end
            end
        end
    end

    return {}
end

return KindleClippingsParser
