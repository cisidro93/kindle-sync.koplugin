local KindleCatalogDb = require("lua/lib/kindle_catalog_db")
local SQ3 = require("lua-ljsqlite3/init")
local logger = require("logger")
local _ = require("gettext")

local KindleCollectionsSync = {}
KindleCollectionsSync.__index = KindleCollectionsSync

KindleCollectionsSync.CC_DB_PATH = "/var/local/cc.db"

function KindleCollectionsSync:new(virtual_library)
    local instance = {
        virtual_library = virtual_library,
    }
    setmetatable(instance, self)
    return instance
end

--- Query collections and their member book paths from cc.db.
--- @return table|nil: list of { name = string, uuid = string, books = { path1, path2, ... } }
--- @return string|nil: error message
function KindleCollectionsSync:getKindleCollections()
    local conn, err = SQ3.open(self.CC_DB_PATH, "ro")
    if not conn then
        return nil, "failed to open cc.db: " .. tostring(err)
    end

    local collections = {}
    local ok, query_err = pcall(function()
        KindleCatalogDb.installIcuCollation(conn)

        -- 1. Fetch collection containers
        local coll_sql = [[
            SELECT p_uuid, p_titles_0_nominal
            FROM Entries
            WHERE p_type IN ('Entry:Collection', 'Collection')
            ORDER BY p_titles_0_nominal
        ]]
        local res, nrow = conn:exec(coll_sql)
        if not res or not nrow or nrow == 0 then
            return
        end

        local coll_by_uuid = {}
        for i = 1, nrow do
            local uuid = res.p_uuid[i]
            local name = res.p_titles_0_nominal[i] or _("Untitled Collection")
            local coll = { uuid = uuid, name = name, book_uuids = {}, books = {} }
            coll_by_uuid[uuid] = coll
            table.insert(collections, coll)
        end

        -- 2. Check for CollectionEntries mapping table
        local table_res = conn:exec("SELECT name FROM sqlite_master WHERE type='table' AND name='CollectionEntries'")
        if table_res and table_res.name and #table_res.name > 0 then
            local map_sql = "SELECT p_collectionUuid, p_itemUuid FROM CollectionEntries"
            local map_res, map_nrow = conn:exec(map_sql)
            if map_res and map_nrow then
                for i = 1, map_nrow do
                    local coll_uuid = map_res.p_collectionUuid[i]
                    local item_uuid = map_res.p_itemUuid[i]
                    if coll_by_uuid[coll_uuid] and item_uuid then
                        table.insert(coll_by_uuid[coll_uuid].book_uuids, item_uuid)
                    end
                end
            end
        else
            -- Check for p_collections or j_collections column in Entries
            local cols_res = conn:exec("PRAGMA table_info(Entries)")
            local has_p_colls = false
            if cols_res and cols_res.name then
                for _, col_name in ipairs(cols_res.name) do
                    if col_name == "p_collections" or col_name == "j_collections" then
                        has_p_colls = col_name
                        break
                    end
                end
            end

            if has_p_colls then
                local item_sql = "SELECT p_uuid, " .. has_p_colls .. " FROM Entries WHERE p_type = 'Entry:Item'"
                local item_res, item_nrow = conn:exec(item_sql)
                if item_res and item_nrow then
                    for i = 1, item_nrow do
                        local item_uuid = item_res.p_uuid[i]
                        local coll_refs = item_res[has_p_colls][i]
                        if coll_refs and coll_refs ~= "" then
                            for coll_uuid in coll_refs:gmatch("[a-zA-Z0-9%-_]+") do
                                if coll_by_uuid[coll_uuid] then
                                    table.insert(coll_by_uuid[coll_uuid].book_uuids, item_uuid)
                                end
                            end
                        end
                    end
                end
            end
        end
    end)

    conn:close()

    if not ok then
        return nil, "error querying Kindle collections: " .. tostring(query_err)
    end

    -- Map book UUIDs to real filesystem paths using VirtualLibrary
    if self.virtual_library then
        for _, coll in ipairs(collections) do
            for _, item_uuid in ipairs(coll.book_uuids) do
                local book = self.virtual_library:getBook("cc:" .. item_uuid)
                if book then
                    local target_path = book.source_path
                    if self.virtual_library.cache_manager and type(self.virtual_library.cache_manager.getCachePaths) == "function" then
                        local cached = self.virtual_library.cache_manager:getCachePaths(book)
                        if cached and self.virtual_library:isBookPrepared(book) then
                            target_path = cached
                        end
                    end
                    if target_path and target_path ~= "" then
                        table.insert(coll.books, target_path)
                    end
                end
            end
        end
    end

    return collections
end

--- Sync all Kindle collections into KOReader's native ReadCollection.
--- @return number: count of collections synced
--- @return number: total books assigned
function KindleCollectionsSync:syncToKOReader()
    local collections, err = self:getKindleCollections()
    if not collections then
        logger.warn("KindleCollectionsSync:", err)
        return 0, 0, err
    end

    local ok, ReadCollection = pcall(require, "readcollection")
    if not ok or not ReadCollection then
        return 0, 0, "ReadCollection module unavailable"
    end

    local synced_colls = 0
    local total_books = 0

    for _, coll in ipairs(collections) do
        if coll.name and coll.name ~= "" and #coll.books > 0 then
            -- Prefix with "Kindle: " or use name directly
            local coll_name = coll.name
            ReadCollection:addCollection(coll_name)
            ReadCollection:addItemsMultiple(coll.books, { coll_name })
            synced_colls = synced_colls + 1
            total_books = total_books + #coll.books
        end
    end

    logger.info("KindleCollectionsSync: synced", synced_colls, "collections with", total_books, "book mappings to KOReader")
    return synced_colls, total_books
end

return KindleCollectionsSync
