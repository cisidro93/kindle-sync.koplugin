---
--- Cross-device reading sync.
---
--- Keeps the reading position of the open book in sync with a sync server
--- (server/kindle_sync_server.py, or any KOReader Progress sync server) so
--- that a book continues where you left off on Kindle, Boox Palma/Go, or any
--- other device running KOReader.
---
--- When it runs:
---   * book opened (ReaderReady) and device woken up: fetch and maybe jump
---   * book closed and device going to sleep: upload
---   * Wi-Fi connects: upload anything that failed while offline, then fetch
---
--- Positions are exact (XPointer/page) when both devices have the same file
--- and fall back to the book percentage when the files differ (e.g. a Kindle
--- KFX book converted on-device vs. an EPUB on a Boox).

local CloudSyncClient = require("lua/lib/cloud_sync_client")
local Policy = require("lua/lib/cloud_sync_policy")
local _ = require("gettext")
local logger = require("logger")
local T = require("ffi/util").template

local CloudSync = {}
CloudSync.__index = CloudSync

local DEFAULTS = {
    enabled = false,
    server_url = nil,
    username = nil,
    userkey = nil,
    device_id = nil,
    device_name = nil,
    auto_sync = true,
    -- "ask" or "silent": what to do when another device is behind this one.
    backward = "ask",
    last_sync_time = 0,
    last_error = nil,
    receipts = {},
    pending = {},
}

--- Default UI/network adapters. Tests replace these with plain functions.
local function defaultDeps()
    local deps = {}
    function deps.now()
        return os.time()
    end
    function deps.showInfo(text, timeout)
        local UIManager = require("ui/uimanager")
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new({ text = text, timeout = timeout }))
    end
    function deps.confirm(text, ok_text, ok_callback, cancel_text, cancel_callback)
        local UIManager = require("ui/uimanager")
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new({
            text = text,
            ok_text = ok_text,
            ok_callback = ok_callback,
            cancel_text = cancel_text,
            cancel_callback = cancel_callback,
        }))
    end
    function deps.isOnline()
        local ok, NetworkMgr = pcall(require, "ui/network/manager")
        if not ok or not NetworkMgr then
            return true
        end
        if NetworkMgr.isOnline then
            local ok_online, online = pcall(NetworkMgr.isOnline, NetworkMgr)
            if ok_online then
                return online and true or false
            end
        end
        local ok_conn, connected = pcall(NetworkMgr.isConnected, NetworkMgr)
        return ok_conn and connected and true or false
    end
    function deps.runWhenOnline(fn)
        local ok, NetworkMgr = pcall(require, "ui/network/manager")
        if ok and NetworkMgr and NetworkMgr.runWhenOnline then
            return NetworkMgr:runWhenOnline(fn)
        end
        return fn()
    end
    function deps.schedule(seconds, fn)
        require("ui/uimanager"):scheduleIn(seconds, fn)
    end
    function deps.deviceModel()
        local ok, Device = pcall(require, "device")
        local model = ok and Device and Device.model
        return type(model) == "string" and model ~= "" and model or "KOReader"
    end
    function deps.gotoPosition(ui, kind, value)
        local Event = require("ui/event")
        if ui.link and ui.link.addCurrentLocationToStack then
            pcall(ui.link.addCurrentLocationToStack, ui.link)
        end
        if kind == "xpointer" then
            ui:handleEvent(Event:new("GotoXPointer", value))
        elseif kind == "page" then
            ui:handleEvent(Event:new("GotoPage", value))
        elseif kind == "percent" then
            ui:handleEvent(Event:new("GotoPercent", value * 100))
        end
    end
    return deps
end

--- @param plugin table Plugin instance; settings live in plugin.settings.cloud_sync.
--- @param deps table|nil Optional adapter overrides (tests).
function CloudSync:new(plugin, deps)
    local o = setmetatable({}, self)
    o.plugin = plugin
    o.deps = defaultDeps()
    for k, v in pairs(deps or {}) do
        o.deps[k] = v
    end
    o.client_factory = (deps and deps.client_factory) or function(opts)
        return CloudSyncClient:new(opts)
    end
    return o
end

--- Settings table, created with defaults on first use.
function CloudSync:settings()
    local plugin_settings = self.plugin.settings
    plugin_settings.cloud_sync = plugin_settings.cloud_sync or {}
    local s = plugin_settings.cloud_sync
    for k, v in pairs(DEFAULTS) do
        if s[k] == nil then
            s[k] = type(v) == "table" and {} or v
        end
    end
    if not s.device_id then
        local bytes = {}
        math.randomseed(os.time() + math.floor((os.clock() or 0) * 1e6))
        for i = 1, 16 do
            bytes[i] = string.format("%02x", math.random(0, 255))
        end
        s.device_id = table.concat(bytes)
    end
    if not s.device_name or s.device_name == "" then
        s.device_name = self.deps.deviceModel()
    end
    return s
end

function CloudSync:save()
    if self.plugin.saveSettings then
        self.plugin:saveSettings()
    end
end

function CloudSync:isPaired()
    local s = self:settings()
    return s.server_url ~= nil and s.username ~= nil and s.userkey ~= nil
end

function CloudSync:isActive()
    local s = self:settings()
    return s.enabled == true and self:isPaired()
end

function CloudSync:client()
    local s = self:settings()
    return self.client_factory({ server_url = s.server_url, username = s.username, userkey = s.userkey })
end

-- ---------------------------------------------------------------------------
-- Status bookkeeping
-- ---------------------------------------------------------------------------

function CloudSync:noteSuccess()
    local s = self:settings()
    s.last_sync_time = self.deps.now()
    s.last_error = nil
end

function CloudSync:noteError(err)
    local s = self:settings()
    s.last_error = err and err.message or tostring(err)
    logger.warn("CloudSync:", s.last_error, err and err.detail or "")
    if err and err.kind == "auth" then
        -- Device was removed on the server; stop retrying with dead credentials.
        s.userkey = nil
        s.enabled = false
    end
end

--- One line describing the current state, for the menu.
function CloudSync:statusText()
    local s = self:settings()
    if not self:isPaired() then
        return _("Not set up")
    end
    if not s.enabled then
        return _("Paused")
    end
    local pending = 0
    for _k in pairs(s.pending) do
        pending = pending + 1
    end
    if s.last_error then
        return T(_("Problem: %1"), s.last_error)
    end
    if pending > 0 then
        return T(_("%1 book(s) waiting for Wi-Fi"), pending)
    end
    return T(_("Synced %1"), Policy.ago(s.last_sync_time, self.deps.now()))
end

-- ---------------------------------------------------------------------------
-- Pairing
-- ---------------------------------------------------------------------------

--- Pairs this device with a server using a code from the server's dashboard.
--- @param server_url string
--- @param code string
--- @param on_done function(ok, message)
function CloudSync:pair(server_url, code, on_done)
    local url = CloudSyncClient.normalizeServerUrl(server_url)
    if not url then
        return on_done(false, _("Enter the server address shown on the sync dashboard, for example 192.168.1.20:8081."))
    end
    code = tostring(code or ""):upper():gsub("[^A-Z0-9]", "")
    if #code < 4 then
        return on_done(false, _("Enter the 6-character pairing code shown on the sync dashboard."))
    end
    local s = self:settings()
    local client = self.client_factory({ server_url = url })
    local ok, result = client:pair(code, s.device_id, s.device_name, self.deps.deviceModel())
    if not ok then
        return on_done(false, result.message)
    end
    s.server_url = url
    s.username = result.username
    s.userkey = result.userkey
    s.enabled = true
    s.last_error = nil
    s.receipts = {}
    s.pending = {}
    self:save()
    return on_done(true, T(_('This device is now paired as "%1". Reading progress will follow you between devices.'), s.device_name))
end

--- Signs in with a username and password, as KOReader's Progress sync does.
function CloudSync:login(server_url, username, password, on_done)
    local url = CloudSyncClient.normalizeServerUrl(server_url)
    if not url or not username or username == "" or not password or password == "" then
        return on_done(false, _("Enter the server address, user name and password."))
    end
    local md5 = require("ffi/sha2").md5
    local key = md5(password)
    local client = self.client_factory({ server_url = url, username = username, userkey = key })
    local ok, result = client:authorize()
    if not ok then
        return on_done(false, result.message)
    end
    local s = self:settings()
    s.server_url, s.username, s.userkey, s.enabled, s.last_error = url, username, key, true, nil
    self:save()
    return on_done(true, _("Signed in. Reading progress will follow you between devices."))
end

function CloudSync:unpair()
    local s = self:settings()
    s.username, s.userkey, s.enabled, s.last_error = nil, nil, false, nil
    s.receipts, s.pending = {}, {}
    self:save()
end

-- ---------------------------------------------------------------------------
-- Reading the open book
-- ---------------------------------------------------------------------------

--- Identity and current position of the open book.
--- @return table|nil { book_key, fingerprint, title, authors, percent, progress, kind }
function CloudSync:readBook(ui)
    if not ui or not ui.document then
        return nil
    end
    local props = ui.doc_props
    if type(props) ~= "table" and ui.document.getProps then
        local ok, p = pcall(ui.document.getProps, ui.document)
        props = ok and p or {}
    end
    props = props or {}
    local file = ui.document.file or ""
    local filename = file:match("([^/]+)$") or file
    filename = filename:gsub("%.[^.]+$", "")
    local title = props.display_title or props.title
    local book_key = Policy.bookKey(title, props.authors, filename)

    local fingerprint = ui.doc_settings and ui.doc_settings.readSetting and ui.doc_settings:readSetting("partial_md5_checksum")
    if not fingerprint and file ~= "" then
        local ok, util = pcall(require, "util")
        if ok and util.partialMD5 then
            fingerprint = util.partialMD5(file)
        end
    end

    local percent, progress, kind
    if ui.paging then
        percent = ui.paging.getLastPercent and ui.paging:getLastPercent()
        progress = ui.paging.getLastProgress and ui.paging:getLastProgress()
        kind = "page"
    elseif ui.rolling then
        percent = ui.rolling.getLastPercent and ui.rolling:getLastPercent()
        progress = ui.rolling.getLastProgress and ui.rolling:getLastProgress()
        kind = "xpointer"
    end
    if not book_key or not fingerprint or type(percent) ~= "number" then
        return nil
    end
    return {
        book_key = book_key,
        fingerprint = fingerprint,
        title = title,
        authors = props.authors,
        percent = math.max(0, math.min(1, percent)),
        progress = progress ~= nil and tostring(progress) or tostring(percent),
        kind = kind,
    }
end

local function percentText(p)
    return string.format("%d%%", math.floor((tonumber(p) or 0) * 100 + 0.5))
end

--- Moves the open book to a server position.
function CloudSync:applyRemote(ui, book, remote)
    local percent = tonumber(remote.percentage) or 0
    local exact = remote.document == book.fingerprint and remote.progress and remote.progress ~= ""
    if exact and book.kind == "page" then
        local page = tonumber(remote.progress)
        if page then
            self.deps.gotoPosition(ui, "page", page)
        else
            exact = false
        end
    elseif exact then
        self.deps.gotoPosition(ui, "xpointer", remote.progress)
    end
    if not exact then
        if book.kind == "page" and ui.document and ui.document.getPageCount then
            local pages = ui.document:getPageCount()
            self.deps.gotoPosition(ui, "page", math.max(1, math.min(pages, math.floor(pages * percent + 0.5))))
        else
            self.deps.gotoPosition(ui, "percent", percent)
        end
    end
    self:recordReceipt(book.book_key, remote.version, percent)
    self.deps.showInfo(T(_("Continued from %1 (%2)."), remote.device or _("another device"), percentText(percent)), 3)
end

function CloudSync:recordReceipt(book_key, version, percent)
    local s = self:settings()
    s.receipts[book_key] = { version = tonumber(version) or 0, percent = percent }
    self:noteSuccess()
    self:save()
end

--- Fetches the server's position for the open book and acts on it.
--- @param ui table ReaderUI
--- @param opts table|nil { interactive, push_if_current } interactive reports problems;
--- push_if_current uploads this device's position when nothing newer is on the server.
function CloudSync:pull(ui, opts)
    opts = opts or {}
    if not self:isActive() then
        return false
    end
    if not opts.interactive and not self.deps.isOnline() then
        self._pull_when_online = true
        return false
    end
    self._pull_when_online = nil
    local book = self:readBook(ui)
    if not book then
        return false
    end
    local client = self:client()
    local ok, remote = client:getProgress(book.book_key)
    if ok and (type(remote) ~= "table" or remote.percentage == nil) then
        ok, remote = client:getProgress(book.fingerprint)
    end
    if not ok then
        self:noteError(remote)
        if opts.interactive then
            self.deps.showInfo(remote.message)
        end
        return false
    end
    self:noteSuccess()

    local s = self:settings()
    local receipt = s.receipts[book.book_key]
    local action = Policy.decidePull(book.percent, remote, receipt, s.device_id)
    logger.dbg("CloudSync: pull", book.book_key, "action", action)
    if action == "none" or action == "ack" then
        if action == "ack" then
            self:recordReceipt(book.book_key, remote.version, book.percent)
        end
        if opts.push_if_current then
            return self:push(ui, { interactive = true })
        end
        if opts.interactive then
            self.deps.showInfo(_("Already up to date."), 2)
        end
        return true
    elseif action == "forward" or (action == "backward" and s.backward == "silent") then
        self:applyRemote(ui, book, remote)
    elseif action == "backward" then
        self.deps.confirm(
            T(
                _("%1 is at %2 (%3), behind your place here (%4).\n\nGo back to %2?"),
                remote.device or _("Another device"),
                percentText(remote.percentage),
                Policy.ago(remote.timestamp, self.deps.now()),
                percentText(book.percent)
            ),
            _("Go back"),
            function()
                self:applyRemote(ui, book, remote)
            end,
            _("Stay here"),
            function()
                self:push(ui, { force = true })
            end
        )
    else -- conflict
        self.deps.confirm(
            T(
                _("You read this book on two devices.\n\n%1: %2 (%3)\nThis device: %4\n\nWhere do you want to continue?"),
                remote.device or _("Other device"),
                percentText(remote.percentage),
                Policy.ago(remote.timestamp, self.deps.now()),
                percentText(book.percent)
            ),
            T(_("Go to %1"), percentText(remote.percentage)),
            function()
                self:applyRemote(ui, book, remote)
            end,
            T(_("Stay at %1"), percentText(book.percent)),
            function()
                self:push(ui, { force = true })
            end
        )
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Uploading
-- ---------------------------------------------------------------------------

function CloudSync:buildPayload(book, force)
    local s = self:settings()
    local receipt = s.receipts[book.book_key]
    return {
        document = book.fingerprint,
        book_key = book.book_key,
        progress = book.progress,
        percentage = book.percent,
        device = s.device_name,
        device_id = s.device_id,
        title = book.title,
        authors = book.authors,
        base_version = receipt and receipt.version or nil,
        force = force or nil,
    }
end

--- Sends one payload. Returns "ok", "queued", "kept_remote" or "error".
function CloudSync:send(payload)
    local s = self:settings()
    local client = self:client()
    local ok, result = client:updateProgress(payload)
    if not ok and result.kind == "conflict" and result.current then
        if Policy.resolvePushConflict(payload.percentage, result.current) == "overwrite" then
            payload.force = true
            ok, result = client:updateProgress(payload)
        else
            -- Another device is further ahead. Keep its position; the reader
            -- is asked where to continue the next time this book opens here.
            s.pending[payload.book_key] = nil
            self:noteSuccess()
            self:save()
            return "kept_remote", result.current
        end
    end
    if ok then
        s.pending[payload.book_key] = nil
        self:recordReceipt(payload.book_key, result.version, payload.percentage)
        return "ok"
    end
    self:noteError(result)
    if result.kind == "network" then
        payload.queued_at = self.deps.now()
        s.pending[payload.book_key] = payload
        s.last_error = nil -- waiting for Wi-Fi is expected, not a problem
        self:save()
        return "queued"
    end
    self:save()
    return "error", result
end

--- Uploads the open book's position.
--- @param opts table|nil { force, interactive }
function CloudSync:push(ui, opts)
    opts = opts or {}
    if not self:isActive() then
        return false
    end
    local book = self:readBook(ui)
    if not book then
        return false
    end
    local s = self:settings()
    local receipt = s.receipts[book.book_key]
    if not opts.force and not opts.interactive and receipt and Policy.samePlace(receipt.percent, book.percent) then
        return true -- nothing new to upload
    end
    local payload = self:buildPayload(book, opts.force)
    if not opts.interactive and not self.deps.isOnline() then
        payload.queued_at = self.deps.now()
        s.pending[book.book_key] = payload
        self:save()
        return true
    end
    local result, detail = self:send(payload)
    if opts.interactive then
        if result == "ok" then
            self.deps.showInfo(T(_("Progress uploaded (%1)."), percentText(book.percent)), 2)
        elseif result == "queued" then
            self.deps.showInfo(_("No connection. Progress will be uploaded when Wi-Fi is back."), 3)
        elseif result == "kept_remote" then
            self.deps.showInfo(
                T(
                    _("%1 is further ahead (%2). Open the book again to choose where to continue."),
                    detail.device or "",
                    percentText(detail.percentage)
                )
            )
        else
            self.deps.showInfo(detail and detail.message or _("Sync failed."))
        end
    elseif result == "kept_remote" then
        self.deps.showInfo(T(_("%1 is further ahead (%2). Kept that position."), detail.device or "", percentText(detail.percentage)), 3)
    end
    return result == "ok" or result == "queued"
end

--- Uploads positions that could not be sent while offline.
--- @return number sent
function CloudSync:flushPending()
    if not self:isActive() then
        return 0
    end
    local s = self:settings()
    local sent = 0
    local keys = {}
    for key in pairs(s.pending) do
        keys[#keys + 1] = key
    end
    for _i, key in ipairs(keys) do
        local result = self:send(s.pending[key])
        if result == "queued" then
            break -- still offline, try again later
        end
        if result == "ok" then
            sent = sent + 1
        end
    end
    return sent
end

-- ---------------------------------------------------------------------------
-- Lifecycle hooks (called from main.lua)
-- ---------------------------------------------------------------------------

function CloudSync:onReaderReady(ui)
    if not self:isActive() or not self:settings().auto_sync then
        return
    end
    -- Let the Kindle reader sync and first render finish before moving.
    self.deps.schedule(1, function()
        if ui and ui.document then
            local ok, err = pcall(self.pull, self, ui)
            if not ok then
                logger.warn("CloudSync: pull failed:", err)
            end
        end
    end)
end

function CloudSync:onCloseDocument(ui)
    -- The next book starts its own periodic-upload clock.
    self._last_periodic_push = nil
    if not self:isActive() or not self:settings().auto_sync then
        return
    end
    local ok, err = pcall(self.push, self, ui)
    if not ok then
        logger.warn("CloudSync: push on close failed:", err)
    end
end

--- While reading, upload at most every few minutes so a device left awake
--- (or one whose battery dies) still hands over a recent position.
CloudSync.PERIODIC_PUSH_SECONDS = 300

function CloudSync:onPageUpdate(ui)
    if not self:isActive() or not self:settings().auto_sync or not ui or not ui.document then
        return
    end
    local now = self.deps.now()
    if self._last_periodic_push and now - self._last_periodic_push < CloudSync.PERIODIC_PUSH_SECONDS then
        return
    end
    if not self._last_periodic_push then
        -- First page turn after opening: start the clock, do not upload yet.
        self._last_periodic_push = now
        return
    end
    self._last_periodic_push = now
    if self.deps.isOnline() then
        local ok, err = pcall(self.push, self, ui)
        if not ok then
            logger.warn("CloudSync: periodic push failed:", err)
        end
    end
end

function CloudSync:onSuspend(ui)
    if not self:isActive() or not self:settings().auto_sync or not ui or not ui.document then
        return
    end
    local ok, err = pcall(self.push, self, ui)
    if not ok then
        logger.warn("CloudSync: push on suspend failed:", err)
    end
end

function CloudSync:onResume(ui)
    if not self:isActive() or not self:settings().auto_sync or not ui or not ui.document then
        return
    end
    -- Wi-Fi is usually still waking up; NetworkConnected finishes the job.
    self._pull_when_online = true
    self.deps.schedule(2, function()
        if self._pull_when_online and ui.document and self.deps.isOnline() then
            pcall(self.pull, self, ui)
        end
    end)
end

function CloudSync:onNetworkConnected(ui)
    if not self:isActive() then
        return
    end
    pcall(self.flushPending, self)
    if self._pull_when_online and ui and ui.document and self:settings().auto_sync then
        pcall(self.pull, self, ui)
    end
end

return CloudSync
