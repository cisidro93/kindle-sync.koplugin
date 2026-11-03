require("busted.runner")()

describe("CloudSyncPolicy", function()
    local Policy

    before_each(function()
        package.loaded["lua/lib/cloud_sync_policy"] = nil
        Policy = require("lua/lib/cloud_sync_policy")
    end)

    describe("bookKey", function()
        it("matches the same book across formats and metadata styles", function()
            local kindle = Policy.bookKey("Dune (Dune Chronicles, Book 1)", "Herbert, Frank")
            local boox = Policy.bookKey("Dune", "Frank Herbert\nBrian Herbert")
            assert.are.equal("dune|frank herbert", kindle)
            assert.are.equal(kindle, boox)
        end)

        it("ignores leading articles, punctuation and case", function()
            assert.are.equal(Policy.bookKey("The Hobbit", "J.R.R. Tolkien"), Policy.bookKey("hobbit", "J R R Tolkien"))
        end)

        it("falls back to the file name when there is no title", function()
            assert.are.equal("file:my book", Policy.bookKey(nil, nil, "My_Book"))
            assert.is_nil(Policy.bookKey("", nil, ""))
        end)

        it("works without an author", function()
            assert.are.equal("dune", Policy.bookKey("Dune", ""))
        end)
    end)

    describe("decidePull", function()
        local me = "me"

        it("does nothing without remote data", function()
            assert.are.equal("none", Policy.decidePull(0.2, nil, nil, me))
            assert.are.equal("none", Policy.decidePull(0.2, {}, nil, me))
        end)

        it("ignores a version it already agreed on", function()
            local remote = { percentage = 0.5, version = 3, device_id = "boox" }
            assert.are.equal("none", Policy.decidePull(0.2, remote, { version = 3, percent = 0.2 }, me))
        end)

        it("jumps forward when only the other device moved", function()
            local remote = { percentage = 0.5, version = 4, device_id = "boox" }
            assert.are.equal("forward", Policy.decidePull(0.2, remote, { version = 3, percent = 0.2 }, me))
        end)

        it("asks before going back when only the other device moved backwards", function()
            local remote = { percentage = 0.1, version = 4, device_id = "boox" }
            assert.are.equal("backward", Policy.decidePull(0.2, remote, { version = 3, percent = 0.2 }, me))
        end)

        it("reports a conflict when both devices moved", function()
            local remote = { percentage = 0.5, version = 4, device_id = "boox" }
            assert.are.equal("conflict", Policy.decidePull(0.3, remote, { version = 3, percent = 0.2 }, me))
        end)

        it("treats a first sync of an unread book as forward", function()
            local remote = { percentage = 0.5, version = 1, device_id = "boox" }
            assert.are.equal("forward", Policy.decidePull(0, remote, nil, me))
        end)

        it("treats a first sync of a book read on both devices as a conflict", function()
            local remote = { percentage = 0.5, version = 1, device_id = "boox" }
            assert.are.equal("conflict", Policy.decidePull(0.3, remote, nil, me))
        end)

        it("acknowledges matching positions and its own uploads", function()
            assert.are.equal("ack", Policy.decidePull(0.5004, { percentage = 0.5, version = 9, device_id = "boox" }, nil, me))
            assert.are.equal("ack", Policy.decidePull(0.7, { percentage = 0.5, version = 9, device_id = me }, nil, me))
        end)
    end)

    describe("resolvePushConflict", function()
        it("overwrites when this device is at least as far", function()
            assert.are.equal("overwrite", Policy.resolvePushConflict(0.6, { percentage = 0.5 }))
        end)

        it("keeps the remote position when it is further ahead", function()
            assert.are.equal("keep_remote", Policy.resolvePushConflict(0.2, { percentage = 0.5 }))
        end)
    end)

    it("formats relative times", function()
        assert.are.equal("never", Policy.ago(nil, 100))
        assert.are.equal("just now", Policy.ago(90, 100))
        assert.are.equal("5 min ago", Policy.ago(1000 - 300, 1000))
        assert.are.equal("yesterday", Policy.ago(0 + 1, 86401 + 1))
    end)
end)
