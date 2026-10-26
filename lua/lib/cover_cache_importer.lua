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

local function getAlternateKindlePath(path)
    if type(path) ~= "string" then
        return nil
    end
    if path:sub(1, 8) == "/mnt/us/" then
        return "/mnt/base-us/" .. path:sub(9)
    elseif path:sub(1, 13) == "/mnt/base-us/" then
        return "/mnt/us/" .. path:sub(14)
    elseif path == "/mnt/us" then
        return "/mnt/base-us"
    elseif path == "/mnt/base-us" then
        return "/mnt/us"
    end
    return nil
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
        local alt_dir = getAlternateKindlePath(directory)
        if alt_dir then
            stmt:clearbind():reset()
            stmt:bind(alt_dir, filename)
            row = stmt:step()
        end
    end
    if not row then
        stmt:close()
        conn:close()
        return nil
    end

    local bookinfo = {
        _is_kindle_cover = true,
    }
    for i, col in ipairs(BOOKINFO_COLS) do
        if col == "pages" then
            bookinfo[col] = tonumber(row[i])
        else
            bookinfo[col] = row[i]
        end

        if col == "cover_w" then
            bookinfo.cover_w = tonumber(row[i])
            bookinfo.cover_h = tonumber(row[i + 1])
            if bookinfo.has_cover == "Y" and bookinfo.cover_w and bookinfo.cover_h then
                -- Keep cover_sizetag synchronized with cover_w x cover_h so
                -- BookInfoManager.isCachedCoverInvalid never invalidates cached Kindle covers.
                bookinfo.cover_sizetag = tostring(bookinfo.cover_w) .. "x" .. tostring(bookinfo.cover_h)
            end
            if not get_cover then
                break
            end
            bookinfo.cover_bb = nil
            if bookinfo.has_cover == "Y" then
                local bbtype = tonumber(row[i + 2])
                local bbstride = tonumber(row[i + 3])
                local cover_blob = row[i + 4]
                if
                    bbtype
                    and bbstride
                    and bookinfo.cover_w
                    and bookinfo.cover_h
                    and bookinfo.cover_w > 0
                    and bookinfo.cover_h > 0
                    and cover_blob
                    and cover_blob[1]
                    and cover_blob[2]
                then
                    local z_ok, cover_data, cover_size = pcall(zstd.zstd_uncompress_ctx, cover_blob[1], cover_blob[2])
                    if z_ok and cover_data then
                        local expected_size = bbstride * bookinfo.cover_h
                        if cover_size == expected_size then
                            local cover_bb = Blitbuffer.new(bookinfo.cover_w, bookinfo.cover_h, bbtype, cover_data, bbstride, bookinfo.cover_w)
                            cover_bb:setAllocated(1)
                            bookinfo.cover_bb = cover_bb
                        else
                            pcall(ffi.C.free, cover_data)
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

--- Build a fallback bookinfo metadata table from cc.db book metadata when no
--- cached cover or local thumbnail JPEG is available. Prevents CoverBrowser from
--- spawning background extraction subprocesses on .kfx files.
--- @param book table
--- @param filepath string
--- @return table|nil
function CoverCacheImporter:buildFallbackBookInfo(book, filepath)
    if not book or not filepath or filepath == "" then
        return nil
    end
    local directory, filename = util.splitFilePathName(filepath)
    local attr = lfs.attributes(filepath)
    local filesize = attr and attr.size or 0
    local filemtime = attr and attr.modification or 0

    local authors_str = nil
    if type(book.authors) == "table" then
        authors_str = table.concat(book.authors, ", ")
    elseif type(book.authors) == "string" then
        authors_str = book.authors
    elseif type(book.author) == "string" then
        authors_str = book.author
    end

    return {
        directory = directory,
        filename = filename,
        filesize = filesize,
        filemtime = filemtime,
        in_progress = 0,
        unsupported = nil,
        cover_fetched = "Y",
        has_meta = "Y",
        has_cover = nil,
        cover_sizetag = nil,
        ignore_meta = nil,
        ignore_cover = "Y",
        pages = nil,
        title = book.title or book.display_name,
        authors = authors_str,
        series = book.series,
        series_index = book.series_index,
        language = book.language,
        keywords = nil,
        description = book.description,
        cover_w = nil,
        cover_h = nil,
        cover_bb = nil,
    }
end

--- Insert a cover record into bookinfo_cache for a specific path.
--- Note: lua-ljsqlite3 binds SQ3.blob with C.free as the SQLite destructor,
--- so each bound row MUST receive its own freshly allocated zstd buffer!
local function insertCoverRow(insert_stmt, path, book, cover_data)
    if cover_data.raw_data == nil or not cover_data.raw_size or cover_data.raw_size <= 0 then
        return false
    end
    local z_ok, zst_ptr, zst_size = pcall(zstd.zstd_compress, cover_data.raw_data, cover_data.raw_size)
    if not z_ok or not zst_ptr or not zst_size or zst_size <= 0 then
        return false
    end

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
        cover_bb_data = SQ3.blob(zst_ptr, zst_size),
    }

    insert_stmt:clearbind():reset()
    for i, col in ipairs(BOOKINFO_COLS) do
        insert_stmt:bind1(i, dbrow[col])
    end
    insert_stmt:step()
    return true
end

--- Enhance color saturation and contrast for color e-ink (Colorsoft / Kaleido 3).
--- Supports both 24-bit RGB (TYPE_BBRGB24, 3 bytes/pixel) and 32-bit RGB/RGBA (TYPE_BBRGB32, 4 bytes/pixel).
--- @param cover_bb table: BlitBuffer
--- @param saturation number|nil: factor e.g. 1.25 (+25% vibrance)
local function enhanceColorsoftVibrance(cover_bb, saturation)
    if not cover_bb or type(cover_bb.getType) ~= "function" then
        return
    end

    local bb_type = cover_bb:getType()
    local bpp
    if bb_type == Blitbuffer.TYPE_BBRGB24 then
        bpp = 3
    elseif bb_type == Blitbuffer.TYPE_BBRGB32 or (Blitbuffer.TYPE_BBRGBA_32 and bb_type == Blitbuffer.TYPE_BBRGBA_32) then
        bpp = 4
    else
        return
    end

    local s = saturation or 1.25
    local w = tonumber(cover_bb.w)
    local h = tonumber(cover_bb.h)
    local stride = tonumber(cover_bb.stride)
    if not w or not h or not stride or w <= 0 or h <= 0 or stride < w * bpp or cover_bb.data == nil then
        return
    end
    local ok, data_ptr = pcall(ffi.cast, "uint8_t*", cover_bb.data)
    if not ok or data_ptr == nil then
        return
    end

    for y = 0, h - 1 do
        local row_offset = y * stride
        for x = 0, w - 1 do
            local idx = row_offset + x * bpp
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
    local max_w = cover_specs and cover_specs.max_cover_w or 500
    local max_h = cover_specs and cover_specs.max_cover_h or 700

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

    -- Store cover_sizetag equal to cover_w x cover_h so BookInfoManager.isCachedCoverInvalid
    -- never treats a cached Kindle thumbnail as downscaled/invalid.
    local cover_data = {
        w = cover_w,
        h = cover_h,
        bb_type = cover_type,
        bb_stride = cover_stride,
        orig_sizetag = tostring(cover_w) .. "x" .. tostring(cover_h),
        raw_data = cover_bb.data,
        raw_size = raw_size,
    }

    local bim = package.loaded["bookinfomanager"]
    if bim and type(bim.closeDbConnection) == "function" then
        pcall(bim.closeDbConnection, bim)
    end

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
    local function addPathAndAlias(p)
        if p and p ~= "" then
            paths_to_cache[p] = true
            local alt = getAlternateKindlePath(p)
            if alt then
                paths_to_cache[alt] = true
            end
        end
    end
    addPathAndAlias(target_path)
    addPathAndAlias(book.source_path)
    if self.cache_manager and type(self.cache_manager.getCachePaths) == "function" then
        local cached_path = self.cache_manager:getCachePaths(book)
        addPathAndAlias(cached_path)
    end

    local any_inserted = false
    for p in pairs(paths_to_cache) do
        if insertCoverRow(insert_stmt, p, book, cover_data) then
            any_inserted = true
        end
    end

    conn:exec("COMMIT;")
    insert_stmt:close()
    conn:close()
    cover_bb:free()

    if not any_inserted then
        return false, "failed to compress cover blitbuffer"
    end

    logger.dbg("CoverCacheImporter: successfully cached cover for", book.id, "from", thumbnail_path)
    return true
end

--- Retrieve a scaled BlitBuffer for a book cover, importing and caching it into
--- bookinfo_cache.sqlite3 first if needed.
--- @param book table
--- @param max_w number|nil
--- @param max_h number|nil
--- @return table|nil: BlitBuffer
function CoverCacheImporter:getBookCoverBb(book, max_w, max_h)
    if not book then
        return nil
    end
    local lookup_path = book.source_path
    if not lookup_path and self.cache_manager and type(self.cache_manager.getCachePaths) == "function" then
        lookup_path = self.cache_manager:getCachePaths(book)
    end

    local cover_bb = nil
    if lookup_path then
        local cached = self:getCachedBookInfo(lookup_path, true)
        if cached and cached.has_cover == "Y" and cached.cover_bb then
            cover_bb = cached.cover_bb
        else
            local ok = self:importBookCover(book, nil, lookup_path)
            if ok then
                local fresh = self:getCachedBookInfo(lookup_path, true)
                if fresh and fresh.has_cover == "Y" and fresh.cover_bb then
                    cover_bb = fresh.cover_bb
                end
            end
        end
    end

    if not cover_bb then
        local thumb_path = self.virtual_library and self.virtual_library:getBookThumbnailPath(book)
        if thumb_path then
            local ok, rendered = pcall(RenderImage.renderImageFile, RenderImage, thumb_path)
            if ok and rendered then
                enhanceColorsoftVibrance(rendered, 1.25)
                cover_bb = rendered
            end
        end
    end

    if cover_bb and max_w and max_h and max_w > 0 and max_h > 0 then
        local w, h = cover_bb:getWidth(), cover_bb:getHeight()
        if w and h and w > 0 and h > 0 and (w ~= max_w or h ~= max_h) then
            local scale = math.min(max_w / w, max_h / h)
            local scaled_w = math.max(1, math.floor(w * scale))
            local scaled_h = math.max(1, math.floor(h * scale))
            local ok_s, scaled = pcall(RenderImage.scaleBlitBuffer, RenderImage, cover_bb, scaled_w, scaled_h, true)
            if ok_s and scaled then
                cover_bb = scaled
            end
        end
    end

    return cover_bb
end

return CoverCacheImporter
