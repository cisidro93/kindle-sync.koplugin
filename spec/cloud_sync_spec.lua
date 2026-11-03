require("busted.runner")()

describe("CloudSync", function()
    local CloudSync
    local plugin, deps, server, shown, moves, online, scheduled

    --- In-memory stand-in for the sync server, with the same conflict rule.
    local function newServer()
        local srv = { records = {}, calls = {}, offline = false }
        function srv.client()
            local c = {}
            function c.getProgress(_, document)
                table.insert(srv.calls, { "get", document })
                if srv.offline then
                    return false, { kind = "network", message = "offline" }
                end
                return true, srv.records[document] or {}
            end
            function c.updateProgress(_, p)
                table.insert(srv.calls, { "put", p.book_key, p.percentage, p.force })
                if srv.offline then
                    return false, { kind = "network", message = "offline" }
                end
                local cur = srv.records[p.book_key]
                if cur and p.base_version and not p.force and cur.version > p.base_version and cur.device_id ~= p.device_id then
                    return false, { kind = "conflict", current = cur }
                end
                local rec = {
                    document = p.document,
                    progress = p.progress,
                    percentage = p.percentage,
                    device = p.device,
                    device_id = p.device_id,
                    version = (cur and cur.version or 0) + 1,
                    timestamp = 1000,
                }
                srv.records[p.book_key] = rec
                return true, { version = rec.version }
            end
            function c.pair(_, code)
                if code ~= "ABC123" then
                    return false, { kind = "pair", message = "That pairing code is wrong or has expired." }
                end
                return true, { username = "reader", userkey = "devkey" }
            end
            return c
        end
        return srv
    end

    local function newUI(percent, opts)
        opts = opts or {}
        local ui = {
            doc_props = { title = opts.title or "Dune", authors = "Frank Herbert" },
            doc_settings = {
                readSetting = function(_, key)
                    if key == "partial_md5_checksum" then
                        return opts.fingerprint or "hash-here"
                    end
                end,
            },
            rolling = {
                getLastPercent = function()
                    return percent
                end,
                getLastProgress = function()
                    return "/body/p[" .. math.floor(percent * 100) .. "]"
                end,
            },
        }
        ui.document = { file = "/books/dune.epub" }
        return ui
    end

    before_each(function()
        package.loaded["lua/cloud_sync"] = nil
        CloudSync = require("lua/cloud_sync")
        server = newServer()
        shown, moves, scheduled = {}, {}, {}
        online = true
        plugin = {
            settings = {},
            saveSettings = function() end,
        }
        deps = {
            now = function()
                return 2000
            end,
            showInfo = function(text)
                table.insert(shown, { kind = "info", text = text })
            end,
            confirm = function(text, ok_text, ok_cb, cancel_text, cancel_cb)
                table.insert(shown, { kind = "confirm", text = text, ok = ok_cb, cancel = cancel_cb, ok_text = ok_text })
            end,
            isOnline = function()
                return online
            end,
            runWhenOnline = function(fn)
                return fn()
            end,
            schedule = function(_, fn)
                table.insert(scheduled, fn)
            end,
            deviceModel = function()
                return "Kindle"
            end,
            gotoPosition = function(_, kind, value)
                table.insert(moves, { kind = kind, value = value })
            end,
            client_factory = function()
                return server.client()
            end,
        }
    end)

    local function paired(name, id)
        local cs = CloudSync:new({ settings = {}, saveSettings = function() end }, deps)
        local s = cs:settings()
        s.server_url, s.username, s.userkey, s.enabled = "http://h", "reader", "k", true
        s.device_name, s.device_id = name, id
        return cs
    end

    it("pairs with a code and reports a bad code", function()
        local cs = CloudSync:new(plugin, deps)
        local result
        cs:pair("192.168.1.2:8081", "abc-123", function(ok, msg)
            result = { ok, msg }
        end)
        assert.is_true(result[1])
        assert.is_true(cs:isActive())
        assert.are.equal("http://192.168.1.2:8081", plugin.settings.cloud_sync.server_url)

        cs:pair("192.168.1.2:8081", "ZZZZZZ", function(ok, msg)
            result = { ok, msg }
        end)
        assert.is_false(result[1])
        assert.is_truthy(result[2]:match("expired"))
    end)

    it("continues on a second device where the first one stopped", function()
        local kindle = paired("Kindle", "kindle")
        local boox = paired("Boox Palma", "boox")

        kindle:onCloseDocument(newUI(0.42, { fingerprint = "kindle-epub" }))
        boox:pull(newUI(0, { fingerprint = "boox-epub" }))

        -- Different files, so the percentage is used rather than the XPointer.
        assert.are.same({ kind = "percent", value = 0.42 }, moves[1])
        assert.is_truthy(shown[#shown].text:match("Kindle"))
    end)

    it("uses the exact position when both devices have the same file", function()
        local kindle = paired("Kindle", "kindle")
        local boox = paired("Boox", "boox")
        kindle:onCloseDocument(newUI(0.42))
        boox:pull(newUI(0))
        assert.are.same({ kind = "xpointer", value = "/body/p[42]" }, moves[1])
    end)

    it("asks where to continue when both devices moved", function()
        local kindle = paired("Kindle", "kindle")
        local boox = paired("Boox", "boox")
        kindle:onCloseDocument(newUI(0.10))
        boox:pull(newUI(0))
        boox:onCloseDocument(newUI(0.30)) -- Boox reads on
        moves = {}
        -- Kindle read offline from 10% to 20% and opens the book again.
        kindle:pull(newUI(0.20))
        local prompt = shown[#shown]
        assert.are.equal("confirm", prompt.kind)
        assert.is_truthy(prompt.text:match("two devices"))
        prompt.ok()
        assert.are.same({ kind = "xpointer", value = "/body/p[30]" }, moves[1])
    end)

    it("keeps this device's place when the reader chooses to stay", function()
        local kindle = paired("Kindle", "kindle")
        local boox = paired("Boox", "boox")
        kindle:onCloseDocument(newUI(0.10))
        boox:pull(newUI(0))
        boox:onCloseDocument(newUI(0.30))
        kindle:pull(newUI(0.20))
        shown[#shown].cancel()
        assert.are.equal(0.20, server.records["dune|frank herbert"].percentage)
        assert.are.equal("kindle", server.records["dune|frank herbert"].device_id)
    end)

    it("asks before jumping backwards", function()
        local kindle = paired("Kindle", "kindle")
        local boox = paired("Boox", "boox")
        kindle:onCloseDocument(newUI(0.50))
        boox:pull(newUI(0))
        -- The Boox user went back to re-read a chapter.
        boox.deps.gotoPosition = function() end
        boox:onCloseDocument(newUI(0.30))
        kindle:pull(newUI(0.50))
        assert.are.equal("confirm", shown[#shown].kind)
        assert.is_truthy(shown[#shown].text:match("behind"))
    end)

    it("queues uploads while offline and sends them when Wi-Fi returns", function()
        local kindle = paired("Kindle", "kindle")
        online = false
        kindle:onSuspend(newUI(0.33))
        assert.are.equal(0, #server.calls)
        assert.is_truthy(kindle:statusText():match("waiting for Wi%-Fi"))

        online = true
        kindle:onNetworkConnected(nil)
        assert.are.equal(0.33, server.records["dune|frank herbert"].percentage)
        assert.is_nil(next(kindle:settings().pending))
    end)

    it("queues when the server is unreachable even though Wi-Fi is up", function()
        local kindle = paired("Kindle", "kindle")
        server.offline = true
        kindle:onCloseDocument(newUI(0.33))
        assert.is_truthy(kindle:settings().pending["dune|frank herbert"])
        assert.is_nil(kindle:settings().last_error)
    end)

    it("does not overwrite a device that is further ahead", function()
        local kindle = paired("Kindle", "kindle")
        local boox = paired("Boox", "boox")
        kindle:onCloseDocument(newUI(0.10))
        boox:pull(newUI(0))
        boox:onCloseDocument(newUI(0.60))
        kindle:onCloseDocument(newUI(0.15))
        assert.are.equal(0.60, server.records["dune|frank herbert"].percentage)
        assert.is_truthy(shown[#shown].text:match("further ahead"))
    end)

    it("skips uploads when nothing changed", function()
        local kindle = paired("Kindle", "kindle")
        kindle:onCloseDocument(newUI(0.10))
        local calls = #server.calls
        kindle:onCloseDocument(newUI(0.10))
        assert.are.equal(calls, #server.calls)
    end)

    it("stops syncing when the server says the device was removed", function()
        local kindle = paired("Kindle", "kindle")
        kindle.client_factory = function()
            return {
                updateProgress = function()
                    return false, { kind = "auth", message = "This device is no longer paired. Pair it again." }
                end,
            }
        end
        kindle:onCloseDocument(newUI(0.10))
        assert.is_false(kindle:isActive())
        assert.is_truthy(kindle:statusText():match("Not set up"))
    end)

    it("does nothing until paired", function()
        local cs = CloudSync:new(plugin, deps)
        assert.is_false(cs:pull(newUI(0.1)))
        assert.is_false(cs:push(newUI(0.1)))
        assert.are.equal(0, #server.calls)
        assert.is_truthy(cs:statusText():match("Not set up"))
    end)
end)
