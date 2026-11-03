---
--- Cross-device sync policy.
---
--- Pure functions (no KOReader dependencies) that decide what to do with a
--- reading position fetched from, or rejected by, the sync server. Keeping the
--- rules here makes them easy to test and keeps cloud_sync.lua about plumbing.

local CloudSyncPolicy = {}

--- Two positions closer than this (0.1% of the book) are "the same place".
--- Different renderers report slightly different percentages for one spot.
CloudSyncPolicy.SAME_PLACE = 0.001

local function lower(text)
    return (tostring(text or "")):lower()
end

--- Normalises a title or author so the same book matches across files and
--- formats: case, punctuation, series suffixes and extra spaces are ignored.
--- @param text string|nil
--- @return string
function CloudSyncPolicy.normalize(text)
    local s = lower(text)
    s = s:gsub("%b()", " "):gsub("%b[]", " ") -- "(Dune Chronicles #1)", "[Kindle Edition]"
    s = s:gsub("^%s*the%s+", ""):gsub("^%s*a%s+", ""):gsub("^%s*an%s+", "")
    s = s:gsub("[%p%c]", " ")
    s = s:gsub("%s+", " ")
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Returns only the first author, normalised. "Herbert, Frank" and
--- "Frank Herbert" both become "frank herbert".
--- @param authors string|nil Newline/semicolon/ampersand separated authors.
--- @return string
function CloudSyncPolicy.firstAuthor(authors)
    local first = tostring(authors or ""):match("^[^\n;&]+") or ""
    local last, given = first:match("^%s*([^,]+),%s*(.+)$")
    if last and given then
        first = given .. " " .. last
    end
    return CloudSyncPolicy.normalize(first)
end

--- Builds the format-independent identity of a book.
--- @param title string|nil
--- @param authors string|nil
--- @param fallback string|nil Used when there is no title (e.g. file name).
--- @return string|nil
function CloudSyncPolicy.bookKey(title, authors, fallback)
    local t = CloudSyncPolicy.normalize(title)
    if t == "" then
        t = CloudSyncPolicy.normalize(fallback)
        if t == "" then
            return nil
        end
        return "file:" .. t
    end
    local a = CloudSyncPolicy.firstAuthor(authors)
    if a == "" then
        return t
    end
    return t .. "|" .. a
end

local function samePlace(a, b)
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) < CloudSyncPolicy.SAME_PLACE
end
CloudSyncPolicy.samePlace = samePlace

--- Decides what to do after fetching the server's position for an open book.
---
--- @param local_percent number Current position on this device, 0..1.
--- @param remote table|nil Server record: percentage, version, device_id.
--- @param receipt table|nil Last agreed state: { version, percent }.
--- @param my_device_id string
--- @return string action One of:
---   "none"     nothing to do (no data, already seen, or same place)
---   "ack"      remote equals local; just remember its version
---   "forward"  another device is further ahead and this one has not moved: jump
---   "backward" another device is behind and this one has not moved: ask first
---   "conflict" both this device and another moved since they last agreed
function CloudSyncPolicy.decidePull(local_percent, remote, receipt, my_device_id)
    if type(remote) ~= "table" or tonumber(remote.percentage) == nil then
        return "none"
    end
    local remote_version = tonumber(remote.version) or 0
    if receipt and tonumber(receipt.version) and remote_version > 0 and remote_version <= tonumber(receipt.version) then
        return "none"
    end
    local remote_percent = tonumber(remote.percentage)
    local here = tonumber(local_percent) or 0
    if samePlace(remote_percent, here) then
        return "ack"
    end
    if remote.device_id and remote.device_id == my_device_id then
        -- Our own last upload; whatever happened locally since is newer.
        return "ack"
    end

    local moved_here
    if receipt and tonumber(receipt.percent) then
        moved_here = not samePlace(here, receipt.percent)
    else
        -- Never synced this book from here: an untouched book has not moved.
        moved_here = here > CloudSyncPolicy.SAME_PLACE
    end
    if moved_here then
        return "conflict"
    end
    if remote_percent > here then
        return "forward"
    end
    return "backward"
end

--- Decides how to resolve a push the server rejected because another device
--- moved first. The furthest position wins automatically; when this device is
--- behind, the other position is kept and the user decides on next open.
--- @param local_percent number
--- @param current table Server's current record.
--- @return string "overwrite" or "keep_remote"
function CloudSyncPolicy.resolvePushConflict(local_percent, current)
    local remote = tonumber(current and current.percentage) or 0
    if (tonumber(local_percent) or 0) + CloudSyncPolicy.SAME_PLACE >= remote then
        return "overwrite"
    end
    return "keep_remote"
end

--- Human friendly "x min ago" text.
--- @param timestamp number|nil
--- @param now number|nil
--- @return string
function CloudSyncPolicy.ago(timestamp, now)
    timestamp = tonumber(timestamp)
    if not timestamp or timestamp <= 0 then
        return "never"
    end
    local delta = math.max(0, (now or os.time()) - timestamp)
    if delta < 60 then
        return "just now"
    elseif delta < 3600 then
        return string.format("%d min ago", math.floor(delta / 60))
    elseif delta < 86400 then
        return string.format("%d h ago", math.floor(delta / 3600))
    end
    local days = math.floor(delta / 86400)
    return days == 1 and "yesterday" or string.format("%d days ago", days)
end

return CloudSyncPolicy
