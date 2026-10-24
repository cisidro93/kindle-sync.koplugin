-- Tests for ReadingGoalTracker module

require("busted.runner")()
local helper = require("spec/test_helper")

describe("ReadingGoalTracker", function()
    local ReadingGoalTracker

    setup(function()
        helper.setup_complete()
        ReadingGoalTracker = require("lua/lib/reading_goal_tracker")
    end)

    before_each(function()
        helper.before_each()
    end)

    it("initializes reading goal data with default 30 mins", function()
        local plugin = { settings = {}, saveSettings = function() end }
        local tracker = ReadingGoalTracker:new(plugin)
        local data = tracker:getData()

        assert.is_not_nil(data)
        assert.equals(30, data.target_minutes)
        assert.equals(0, data.today_minutes)
        assert.equals(0, data.streak_days)
    end)

    it("records reading minutes and increments streak when target reached", function()
        local plugin = { settings = {}, saveSettings = function() end }
        local tracker = ReadingGoalTracker:new(plugin)

        tracker:recordMinutes(20)
        local data = tracker:getData()
        assert.equals(20, data.today_minutes)
        assert.equals(0, data.streak_days)

        tracker:recordMinutes(15)
        data = tracker:getData()
        assert.equals(35, data.today_minutes)
        assert.equals(1, data.streak_days)
    end)
end)
