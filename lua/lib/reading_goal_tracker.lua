local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template

local ReadingGoalTracker = {}
ReadingGoalTracker.__index = ReadingGoalTracker

function ReadingGoalTracker:new(plugin)
    local instance = {
        plugin = plugin,
        session_start_time = nil,
    }
    setmetatable(instance, self)
    return instance
end

local function getTodayString()
    return os.date("%Y-%m-%d")
end

local function getYesterdayString()
    return os.date("%Y-%m-%d", os.time() - 86400)
end

function ReadingGoalTracker:getData()
    local settings = self.plugin and self.plugin.settings or {}
    local data = settings.reading_goals
    if not data or type(data) ~= "table" then
        data = {
            target_minutes = 30,
            today_minutes = 0,
            streak_days = 0,
            longest_streak = 0,
            last_day = getTodayString(),
        }
        if self.plugin then
            self.plugin.settings.reading_goals = data
        end
    end

    -- If new day has dawned, rotate today's minutes
    local today = getTodayString()
    if data.last_day ~= today then
        local yesterday = getYesterdayString()
        if data.last_day ~= yesterday then
            -- Streak broken
            if data.today_minutes < (data.target_minutes or 30) then
                data.streak_days = 0
            end
        else
            -- Was yesterday: check if yesterday reached goal
            if data.today_minutes < (data.target_minutes or 30) then
                data.streak_days = 0
            end
        end
        data.today_minutes = 0
        data.last_day = today
        if self.plugin then
            self.plugin:saveSettings()
        end
    end

    return data
end

function ReadingGoalTracker:startSession()
    self.session_start_time = os.time()
end

function ReadingGoalTracker:endSession()
    if not self.session_start_time then
        return 0
    end

    local elapsed_seconds = os.time() - self.session_start_time
    self.session_start_time = nil
    if elapsed_seconds < 10 then
        return 0
    end

    local elapsed_minutes = math.floor(elapsed_seconds / 60)
    if elapsed_minutes < 1 then
        elapsed_minutes = 1
    end

    return self:recordMinutes(elapsed_minutes)
end

function ReadingGoalTracker:recordMinutes(minutes)
    local data = self:getData()
    local before = data.today_minutes or 0
    data.today_minutes = before + minutes

    local target = data.target_minutes or 30
    if before < target and data.today_minutes >= target then
        -- Daily Goal Reached!
        data.streak_days = (data.streak_days or 0) + 1
        if (data.longest_streak or 0) < data.streak_days then
            data.longest_streak = data.streak_days
        end
        UIManager:show(InfoMessage:new({
            text = T(_("🎉 Daily Reading Goal Reached!\n%1 mins read today • %2-day streak 🔥"), data.today_minutes, data.streak_days),
            timeout = 5,
        }))
    end

    if self.plugin then
        self.plugin:saveSettings()
    end

    logger.info("ReadingGoalTracker: recorded", minutes, "mins, today total:", data.today_minutes, "streak:", data.streak_days)
    return data.today_minutes
end

function ReadingGoalTracker:showDashboard()
    local data = self:getData()
    local target = data.target_minutes or 30
    local today_mins = data.today_minutes or 0
    local streak = data.streak_days or 0
    local longest = data.longest_streak or streak

    local percent = math.min(100, math.floor((today_mins / target) * 100))
    local progress_bar_length = 20
    local filled = math.floor((percent / 100) * progress_bar_length)
    local empty = progress_bar_length - filled
    local bar = "[" .. string.rep("=", filled) .. string.rep(" ", empty) .. "]"

    local status_line
    if today_mins >= target then
        status_line = T(_("Goal Achieved! You reached your %1 min daily target."), target)
    else
        status_line = T(_("%1 mins remaining to achieve today's goal."), target - today_mins)
    end

    local text = string.format(
        "%s\n%s %d%%\n%s\n\n%s: %s\n%s: %s\n%s: %d %s",
        bar,
        _("Progress:"),
        percent,
        status_line,
        _("Today's Reading"),
        T(_("%1 / %2 minutes"), today_mins, target),
        _("Current Streak"),
        T(_("%1 days 🔥"), streak),
        _("Longest Streak"),
        longest,
        _("days")
    )

    local ButtonDialog = require("ui/widget/buttondialog")
    local dashboard
    dashboard = ButtonDialog:new({
        title = _("Kindle Daily Reading Goals"),
        text = text,
        buttons = {
            {
                {
                    text = _("Set Target (15m)"),
                    callback = function()
                        data.target_minutes = 15
                        if self.plugin then
                            self.plugin:saveSettings()
                        end
                        UIManager:close(dashboard)
                        self:showDashboard()
                    end,
                },
                {
                    text = _("Set Target (30m)"),
                    callback = function()
                        data.target_minutes = 30
                        if self.plugin then
                            self.plugin:saveSettings()
                        end
                        UIManager:close(dashboard)
                        self:showDashboard()
                    end,
                },
                {
                    text = _("Set Target (45m)"),
                    callback = function()
                        data.target_minutes = 45
                        if self.plugin then
                            self.plugin:saveSettings()
                        end
                        UIManager:close(dashboard)
                        self:showDashboard()
                    end,
                },
                {
                    text = _("Set Target (60m)"),
                    callback = function()
                        data.target_minutes = 60
                        if self.plugin then
                            self.plugin:saveSettings()
                        end
                        UIManager:close(dashboard)
                        self:showDashboard()
                    end,
                },
            },
            {
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(dashboard)
                    end,
                },
            },
        },
    })
    UIManager:show(dashboard)
end

return ReadingGoalTracker
