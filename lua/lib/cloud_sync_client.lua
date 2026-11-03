---
--- HTTP client for the cross-device sync server.
---
--- Speaks KOReader's Progress sync (kosync) protocol plus the small
--- extensions in server/kindle_sync_server.py. Every call returns
--- `ok, result_or_error`, where an error is a table
--- `{ kind = "network"|"auth"|"conflict"|"server"|"config", message = string, status = number|nil, current = table|nil }`
--- with a message written for the reader, not for a developer.

local CloudSyncClient = {}
CloudSyncClient.__index = CloudSyncClient

-- Short timeouts: syncing must never make closing a book feel slow.
local CONNECT_TIMEOUT = 3
local TOTAL_TIMEOUT = 8

local function urlEncode(text)
    return (tostring(text):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end
CloudSyncClient.urlEncode = urlEncode

--- Cleans up a server address typed on an e-reader keyboard.
--- "sync.example.com:8081/" → "http://sync.example.com:8081"
--- @param url string|nil
--- @return string|nil
function CloudSyncClient.normalizeServerUrl(url)
    if type(url) ~= "string" then
        return nil
    end
    url = url:gsub("^%s+", ""):gsub("%s+$", "")
    if url == "" then
        return nil
    end
    if not url:match("^%a[%w+.-]*://") then
        url = "http://" .. url
    end
    url = url:gsub("/+$", "")
    if not url:match("^https?://[^/%s]+") then
        return nil
    end
    return url
end

--- Default transport built on KOReader's LuaSocket/LuaSec.
--- @return function(method, url, headers, body, timeouts) -> status|nil, body|err
local function defaultTransport(method, url, headers, body, timeouts)
    local ltn12 = require("ltn12")
    local http = url:match("^https://") and require("ssl.https") or require("socket.http")
    local ok_su, socketutil = pcall(require, "socketutil")
    if ok_su and socketutil then
        socketutil:set_timeout(timeouts.connect, timeouts.total)
    end
    local chunks = {}
    local ok, code = pcall(function()
        local _, status = http.request({
            url = url,
            method = method,
            headers = headers,
            source = body and ltn12.source.string(body) or nil,
            sink = ltn12.sink.table(chunks),
        })
        return status
    end)
    if ok_su and socketutil then
        socketutil:reset_timeout()
    end
    if not ok then
        return nil, tostring(code)
    end
    if type(code) ~= "number" then
        return nil, tostring(code)
    end
    return code, table.concat(chunks)
end

--- @param opts table { server_url, username, userkey, json, transport }
function CloudSyncClient:new(opts)
    opts = opts or {}
    local o = setmetatable({}, self)
    o.server_url = CloudSyncClient.normalizeServerUrl(opts.server_url)
    o.username = opts.username
    o.userkey = opts.userkey
    o.json = opts.json or require("json")
    o.transport = opts.transport or defaultTransport
    o.timeouts = { connect = opts.connect_timeout or CONNECT_TIMEOUT, total = opts.total_timeout or TOTAL_TIMEOUT }
    return o
end

local function networkMessage(err)
    err = tostring(err or "")
    if err:match("timeout") then
        return "The sync server did not answer in time."
    elseif err:match("refused") then
        return "The sync server refused the connection. Is it running?"
    elseif err:match("host") or err:match("resolve") or err:match("name") then
        return "The sync server address could not be found."
    end
    return "Could not reach the sync server."
end

--- Performs one request and turns any failure into a friendly error.
function CloudSyncClient:request(method, path, payload, authenticated)
    if not self.server_url then
        return false, { kind = "config", message = "Set up cross-device sync first." }
    end
    local headers = {
        ["Accept"] = "application/vnd.koreader.v1+json",
    }
    if authenticated ~= false then
        if not self.username or not self.userkey then
            return false, { kind = "config", message = "This device is not paired yet." }
        end
        headers["x-auth-user"] = self.username
        headers["x-auth-key"] = self.userkey
    end
    local body
    if payload ~= nil then
        body = self.json.encode(payload)
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
    end

    local status, response = self.transport(method, self.server_url .. path, headers, body, self.timeouts)
    if not status then
        return false, { kind = "network", message = networkMessage(response), detail = response }
    end

    local data
    if type(response) == "string" and response ~= "" then
        local ok, decoded = pcall(self.json.decode, response)
        if ok and type(decoded) == "table" then
            data = decoded
        end
    end

    if status >= 200 and status < 300 then
        if not data then
            if response == nil or response == "" then
                return true, {}
            end
            return false, { kind = "server", status = status, message = "That address does not look like a sync server." }
        end
        return true, data
    end

    local message = data and data.message
    if status == 401 then
        return false, { kind = "auth", status = status, message = message or "This device is no longer paired. Pair it again." }
    elseif status == 409 then
        return false, { kind = "conflict", status = status, message = message or "Another device moved on.", current = data and data.current }
    elseif status == 429 then
        -- Locked out after failed sign-ins: retry later, like being offline.
        return false, { kind = "network", status = status, message = message or "The sync server is busy. Try again later." }
    elseif status == 404 and data and data.code == "pair_code_invalid" then
        return false, { kind = "pair", status = status, message = message }
    end
    return false,
        {
            kind = "server",
            status = status,
            message = message or string.format("The sync server returned an error (%d).", status),
        }
end

function CloudSyncClient:healthcheck()
    return self:request("GET", "/healthcheck", nil, false)
end

function CloudSyncClient:authorize()
    return self:request("GET", "/users/auth")
end

--- Exchanges a pairing code for this device's credentials.
function CloudSyncClient:pair(code, device_id, device_name, device_model)
    return self:request("POST", "/v1/pair", {
        code = code,
        device_id = device_id,
        device_name = device_name,
        device_model = device_model,
    }, false)
end

--- @param document string Book key or file fingerprint.
function CloudSyncClient:getProgress(document)
    return self:request("GET", "/syncs/progress/" .. urlEncode(document))
end

--- @param progress table kosync fields plus book_key/title/authors/base_version/force.
function CloudSyncClient:updateProgress(progress)
    return self:request("PUT", "/syncs/progress", progress)
end

return CloudSyncClient
