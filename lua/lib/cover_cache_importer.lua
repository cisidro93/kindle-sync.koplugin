local Blitbuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local RenderImage = require("ui/renderimage")
local SQ3 = require("lua-ljsqlite3/init")
local ffi = require("ffi")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local zstd = require("ffi/zstd")

local CoverCacheImporter = {}
CoverCacheImporter.__index = CoverCacheImporter

local BOOKINFO_COLS = {
    "directory",
    "filename",
    "filesize",
    "filemtime",
    "in_progress",
    "unsupported",
    "cover_fetched",
    "has_meta",
    "has_cover",
    "cover_sizetag",
    "ignore_meta",
    "ignore_cover",
    "pages",
    "title",
    "authors",
    "series",
    "series_index",
    "language",
    "keywords",
    "description",
    "cover_w",
    "cover_h",
    "cover_bb_type",
    "cover_bb_stride",
    "cover_bb_data",
}

local INSERT_SQL = "INSERT OR REPLACE INTO bookinfo ("
    .. table.concat(BOOKINFO_COLS, ",")
    .. ") VALUES ("
    .. string.rep("?,", #BOOKINFO_COLS - 1)
    .. "?);"

local SELECT_SQL = "SELECT " .. table.concat(BOOKINFO_COLS, ",") .. " FROM bookinfo WHERE directory=? AND filename=? AND in_progress=0;"

function CoverCacheImporter:new(virtual_library, cache_manager)
    local instance = {
        virtual_library = virtual_library,
        cache_manager = cache_manager,
    }
    setmetatable(instance, self)
    return instance
end

function CoverCacheImporter:getDbPath()
    return DataStorage:getFullDataDir() .. "/settings/bookinfo_cache.sqlite3"
end

function CoverCacheImporter:openDb()
    local db_path = self:getDbPath()
    local lfs_attr = lfs.attributes(db_path)
    if not lfs_attr or lfs_attr.mode ~= "file" then
        return nil, "database file does not exist"
    end
    local conn, err = SQ3.open(db_path)
    if not conn then
        return nil, "failed to open bookinfo_cache: " .. tostring(err)
    end
    return conn
end

--- Query cached cover directly from bookinfo_cache.sqlite3.
--- @param filepath string
--- @param get_cover boolean
--- @return table|nil
function CoverCacheImporter:getCachedBookInfo(filepath, get_cover)
    if not filepath or filepath == "" then
        return nil
    end

    local directory, filename = util.splitFilePathName(filepath)
    local conn, err = self:openDb()
    if not conn then
        return nil, err
    end

    local stmt
    local ok, prep_err = pcall(function()
        stmt = conn:prepare(SELECT_SQL)
    end)
    if not ok or not stmt then
        conn:close()
        return nil, prep_err
    end

    stmt:bind(directory, filename)
    local row = stmt:step()
    if not row then
        stmt:close()
        conn:close()
        return nil
    end

    local bookinfo = {}
    for i, col in ipairs(BOOKINFO_COLS) do
        if col == "pages" then
            bookinfo[col] = tonumber(row[i])
        else
            bookinfo[col] = row[i]
        end

        if col == "cover_w" then
            bookinfo.cover_w = tonumber(row[i])
            bookinfo.cover_h = tonumber(row[i + 1])
            if not get_cover then
                break
            end
            bookinfo.cover_bb = nil
            if bookinfo.has_cover then
                local bbtype = tonumber(row[i + 2])
                local bbstride = tonumber(row[i + 3])
                local cover_blob = row[i + 4]
                if cover_blob and cover_blob[1] and cover_blob[2] then
                    local cover_data, cover_size = zstd.zstd_uncompress_ctx(cover_blob[1], cover_blob[2])
                    if cover_data then
                        local expected_size = bbstride * bookinfo.cover_h
                        if cover_size == expected_size then
                            local cover_bb = Blitbuffer.new(bookinfo.cover_w, bookinfo.cover_h, bbtype, cover_data, bbstride, bookinfo.cover_w)
                            cover_bb:setAllocated(1)
                            bookinfo.cover_bb = cover_bb
                        end
                    end
                end
            end
            break
        end
    end

    stmt:close()
    conn:close()
    return bookinfo
end

--- Insert a cover record into bookinfo_cache for a specific path.
local function insertCoverRow(insert_stmt, path, book, cover_data)
    local directory, filename = util.splitFilePathName(path)
    local attr = lfs.attributes(path)
    local filesize = attr and attr.size or 0
    local filemtime = attr and attr.modification or os.time()

    local authors_str = nil
    if type(book.authors) == "table" then
        authors_str = table.concat(book.authors, ", ")
    elseif type(book.authors) == "string" then
        authors_str = book.authors
    end

    local dbrow = {
        directory = directory,
        filename = filename,
        filesize = filesize,
        filemtime = filemtime,
        in_progress = 0,
        unsupported = nil,
        cover_fetched = "Y",
        has_meta = "Y",
        has_cover = "Y",
        cover_sizetag = cover_data.orig_sizetag,
        ignore_meta = nil,
        ignore_cover = nil,
        pages = nil,
        title = book.title,
        authors = authors_str,
        series = nil,
        series_index = nil,
        language = nil,
        keywords = nil,
        description = nil,
        cover_w = cover_data.w,
        cover_h = cover_data.h,
        cover_bb_type = cover_data.bb_type,
        cover_bb_stride = cover_data.bb_stride,
        cover_bb_data = cover_data.blob,
    }

    insert_stmt:clearbind():reset()
    for i, col in ipairs(BOOKINFO_COLS) do
        insert_stmt:bind1(i, dbrow[col])
    end
    insert_stmt:step()
end

--- Enhance color saturation and contrast for color e-ink (Colorsoft / Kaleido 3).
--- @param cover_bb table: BlitBuffer
--- @param saturation number|nil: factor e.g. 1.25 (+25% vibrance)
local function enhanceColorsoftVibrance(cover_bb, saturation)
    if not cover_bb or type(cover_bb.getType) ~= "function" or cover_bb:getType() ~= Blitbuffer.TYPE_BBRGBA_32 then
        return
    end

    local s = saturation or 1.25
    local w = cover_bb.w
    local h = cover_bb.h
    local stride = tonumber(cover_bb.stride)
    local ok, data_ptr = pcall(ffi.cast, "uint8_t*", cover_bb.data)
    if not ok or not data_ptr then
        return
    end

    for y = 0, h - 1 do
        local row_offset = y * stride
        for x = 0, w - 1 do
            local idx = row_offset + x * 4
            local r = data_ptr[idx]
            local g = data_ptr[idx + 1]
            local b = data_ptr[idx + 2]

            local lum = 0.299 * r + 0.587 * g + 0.114 * b
            local new_r = lum + (r - lum) * s
            local new_g = lum + (g - lum) * s
            local new_b = lum + (b - lum) * s

            data_ptr[idx] = new_r < 0 and 0 or (new_r > 255 and 255 or new_r)
            data_ptr[idx + 1] = new_g < 0 and 0 or (new_g > 255 and 255 or new_g)
            data_ptr[idx + 2] = new_b < 0 and 0 or (new_b > 255 and 255 or new_b)
        end
    end
end

--- Import and cache cover for a single Kindle book.
--- @param book table
--- @param cover_specs table|nil
--- @param target_path string|nil
--- @return boolean, string|nil
function CoverCacheImporter:importBookCover(book, cover_specs, target_path)
    if not book then
        return false, "missing book"
    end

    local thumbnail_path = self.virtual_library and self.virtual_library:getBookThumbnailPath(book)
    if not thumbnail_path then
        return false, "no thumbnail found for book"
    end

    local cover_bb = RenderImage:renderImageFile(thumbnail_path)
    if not cover_bb then
        return false, "failed to render thumbnail: " .. tostring(thumbnail_path)
    end

    local orig_w, orig_h = cover_bb:getWidth(), cover_bb:getHeight()
    local max_w = cover_specs and cover_specs.max_cover_w or 300
    local max_h = cover_specs and cover_specs.max_cover_h or 400

    if orig_w > max_w or orig_h > max_h then
        local scale = math.min(max_w / orig_w, max_h / orig_h)
        local scaled_w = math.max(1, math.floor(orig_w * scale))
        local scaled_h = math.max(1, math.floor(orig_h * scale))
        cover_bb = RenderImage:scaleBlitBuffer(cover_bb, scaled_w, scaled_h, true)
    end

    -- Boost color vibrance for Kindle Colorsoft (Kaleido 3 color e-ink)
    enhanceColorsoftVibrance(cover_bb, 1.25)

    local cover_stride = tonumber(cover_bb.stride)
    local cover_h = cover_bb.h
    local cover_w = cover_bb.w
    local cover_type = cover_bb:getType()
    local raw_size = cover_stride * cover_h

    local zst_ptr, zst_size = zstd.zstd_compress(cover_bb.data, raw_size)
    if not zst_ptr or zst_size <= 0 then
        cover_bb:free()
        return false, "failed to compress cover blitbuffer"
    end

    local cover_data = {
        w = cover_w,
        h = cover_h,
        bb_type = cover_type,
        bb_stride = cover_stride,
        orig_sizetag = orig_w .. "x" .. orig_h,
        blob = SQ3.blob(zst_ptr, zst_size),
    }

    local conn, err = self:openDb()
    if not conn then
        cover_bb:free()
        return false, err
    end

    local insert_stmt
    local ok, prep_err = pcall(function()
        insert_stmt = conn:prepare(INSERT_SQL)
    end)
    if not ok or not insert_stmt then
        cover_bb:free()
        conn:close()
        return false, prep_err
    end

    conn:exec("BEGIN TRANSACTION;")

    local paths_to_cache = {}
    if target_path and target_path ~= "" then
        paths_to_cache[target_path] = true
    end
    if book.source_path and book.source_path ~= "" then
        paths_to_cache[book.source_path] = true
    end
    if self.cache_manager and type(self.cache_manager.getCachePaths) == "function" then
        local cached_path = self.cache_manager:getCachePaths(book)
        if cached_path and cached_path ~= "" then
            paths_to_cache[cached_path] = true
        end
    end

    for p in pairs(paths_to_cache) do
        insertCoverRow(insert_stmt, p, book, cover_data)
    end

    conn:exec("COMMIT;")
    insert_stmt:close()
    conn:close()
    cover_bb:free()

    logger.dbg("CoverCacheImporter: successfully cached cover for", book.id, "from", thumbnail_path)
    return true
end

return CoverCacheImporter
