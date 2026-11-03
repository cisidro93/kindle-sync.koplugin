require("busted.runner")()

describe("CloudSyncClient", function()
    local Client
    local json

    before_each(function()
        package.loaded["lua/lib/cloud_sync_client"] = nil
        Client = require("lua/lib/cloud_sync_client")
        json = require("json")
    end)

    local function fakeTransport(status, response, calls)
        return function(method, url, headers, body)
            table.insert(calls, { method = method, url = url, headers = headers, body = body })
            return status, response
        end
    end

    it("normalises server addresses typed on a device", function()
        assert.are.equal("http://192.168.1.20:8081", Client.normalizeServerUrl(" 192.168.1.20:8081/ "))
        assert.are.equal("https://sync.example.com", Client.normalizeServerUrl("https://sync.example.com"))
        assert.is_nil(Client.normalizeServerUrl(""))
        assert.is_nil(Client.normalizeServerUrl(nil))
    end)

    it("sends kosync auth headers and encodes the document", function()
        local calls = {}
        local c = Client:new({
            server_url = "host:1",
            username = "reader",
            userkey = "k",
            transport = fakeTransport(200, json.encode({ percentage = 0.5 }), calls),
        })
        local ok, data = c:getProgress("dune|frank herbert")
        assert.is_true(ok)
        assert.are.equal(0.5, data.percentage)
        assert.are.equal("http://host:1/syncs/progress/dune%7Cfrank%20herbert", calls[1].url)
        assert.are.equal("reader", calls[1].headers["x-auth-user"])
        assert.are.equal("k", calls[1].headers["x-auth-key"])
    end)

    it("does not send credentials when pairing", function()
        local calls = {}
        local c = Client:new({ server_url = "host:1", transport = fakeTransport(200, json.encode({ username = "reader" }), calls) })
        local ok = c:pair("ABC123", "id", "Kindle", "KindlePaperWhite5")
        assert.is_true(ok)
        assert.is_nil(calls[1].headers["x-auth-user"])
        assert.are.equal("ABC123", json.decode(calls[1].body).code)
    end)

    it("reports a friendly network error", function()
        local c = Client:new({
            server_url = "host:1",
            username = "u",
            userkey = "k",
            transport = function()
                return nil, "connection refused"
            end,
        })
        local ok, err = c:authorize()
        assert.is_false(ok)
        assert.are.equal("network", err.kind)
        assert.is_truthy(err.message:match("refused"))
    end)

    it("maps 401 and 409 to auth and conflict errors", function()
        local c = Client:new({ server_url = "h", username = "u", userkey = "k", transport = fakeTransport(401, "{}", {}) })
        local ok, err = c:authorize()
        assert.is_false(ok)
        assert.are.equal("auth", err.kind)

        c = Client:new({
            server_url = "h",
            username = "u",
            userkey = "k",
            transport = fakeTransport(409, json.encode({ code = "conflict", current = { percentage = 0.7 } }), {}),
        })
        ok, err = c:updateProgress({ document = "d" })
        assert.is_false(ok)
        assert.are.equal("conflict", err.kind)
        assert.are.equal(0.7, err.current.percentage)
    end)

    it("refuses to call the server before it is configured", function()
        local ok, err = Client:new({}):getProgress("x")
        assert.is_false(ok)
        assert.are.equal("config", err.kind)
        ok, err = Client:new({ server_url = "h" }):getProgress("x")
        assert.is_false(ok)
        assert.are.equal("config", err.kind)
    end)

    it("rejects a non-JSON success response", function()
        local c = Client:new({ server_url = "h", transport = fakeTransport(200, "<html>router login</html>", {}) })
        local ok, err = c:healthcheck()
        assert.is_false(ok)
        assert.is_truthy(err.message:match("sync server"))
    end)
end)
