---
--- "Cross-device sync" menu for the plugin.
---
--- Built so the first screen answers two questions: is sync working, and what
--- do I do next. Setup is one dialog (server address + pairing code).

local _ = require("gettext")
local T = require("ffi/util").template

local CloudSyncMenu = {}

local function showPairDialog(plugin, cloud_sync)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local UIManager = require("ui/uimanager")
    local s = cloud_sync:settings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Pair this device"),
        description = _('Open the sync dashboard in a browser, tap "Get a pairing code", then enter the address and code shown there.'),
        fields = {
            { text = s.server_url or "", hint = _("Server address, e.g. 192.168.1.20:8081") },
            { text = "", hint = _("Pairing code, e.g. K7M2QX") },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Pair"),
                    is_enter_default = true,
                    callback = function()
                        local fields = dialog:getFields()
                        UIManager:close(dialog)
                        cloud_sync.deps.runWhenOnline(function()
                            cloud_sync:pair(fields[1], fields[2], function(ok, message)
                                plugin:showInfo(message, ok and 4 or nil)
                            end)
                        end)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function showLoginDialog(plugin, cloud_sync)
    local MultiInputDialog = require("ui/widget/multiinputdialog")
    local UIManager = require("ui/uimanager")
    local s = cloud_sync:settings()
    local dialog
    dialog = MultiInputDialog:new({
        title = _("Sign in to a sync server"),
        description = _("Use this for a KOReader Progress sync server that has no pairing codes."),
        fields = {
            { text = s.server_url or "", hint = _("Server address") },
            { text = s.username or "", hint = _("User name") },
            { text = "", hint = _("Password"), text_type = "password" },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Sign in"),
                    is_enter_default = true,
                    callback = function()
                        local f = dialog:getFields()
                        UIManager:close(dialog)
                        cloud_sync.deps.runWhenOnline(function()
                            cloud_sync:login(f[1], f[2], f[3], function(ok, message)
                                plugin:showInfo(message, ok and 4 or nil)
                            end)
                        end)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

local function showRenameDialog(cloud_sync)
    local InputDialog = require("ui/widget/inputdialog")
    local UIManager = require("ui/uimanager")
    local s = cloud_sync:settings()
    local dialog
    dialog = InputDialog:new({
        title = _("Device name"),
        description = _('Shown on other devices, e.g. "Continued from Boox Palma".'),
        input = s.device_name,
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    is_enter_default = true,
                    callback = function()
                        local name = (dialog:getInputText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if name ~= "" then
                            s.device_name = name
                            cloud_sync:save()
                        end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    })
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- @param plugin table KindlePlugin instance
--- @param cloud_sync table CloudSync instance
function CloudSyncMenu.build(plugin, cloud_sync)
    local function paired()
        return cloud_sync:isPaired()
    end
    local function bookOpen()
        return plugin.ui ~= nil and plugin.ui.document ~= nil
    end

    return {
        text = _("Cross-device sync"),
        help_text = _("Continue reading where you left off on Kindle, Boox or any other device running KOReader."),
        sub_item_table_func = function()
            local s = cloud_sync:settings()
            return {
                {
                    text_func = function()
                        return T(_("Status: %1"), cloud_sync:statusText())
                    end,
                    keep_menu_open = true,
                    callback = function()
                        if not paired() then
                            plugin:showInfo(
                                _(
                                    'Cross-device sync is not set up.\n\n1. Start the sync server on a computer or NAS (see the README).\n2. Open its dashboard and tap "Get a pairing code".\n3. Here, choose "Pair this device".'
                                )
                            )
                            return
                        end
                        local pending = 0
                        for _k in pairs(s.pending) do
                            pending = pending + 1
                        end
                        plugin:showInfo(
                            T(
                                _("Server: %1\nThis device: %2\nLast sync: %3\nWaiting for Wi-Fi: %4\n%5"),
                                s.server_url,
                                s.device_name,
                                require("lua/lib/cloud_sync_policy").ago(s.last_sync_time),
                                pending,
                                s.last_error and T(_("Last problem: %1"), s.last_error) or ""
                            )
                        )
                    end,
                    separator = true,
                },
                {
                    text_func = function()
                        return paired() and _("Pair again with a new code…") or _("Pair this device…")
                    end,
                    keep_menu_open = true,
                    callback = function()
                        showPairDialog(plugin, cloud_sync)
                    end,
                },
                {
                    text = _("Sync this book now"),
                    enabled_func = function()
                        return cloud_sync:isActive() and bookOpen()
                    end,
                    callback = function()
                        cloud_sync.deps.runWhenOnline(function()
                            cloud_sync:flushPending()
                            cloud_sync:pull(plugin.ui, { interactive = true, push_if_current = true })
                        end)
                    end,
                    separator = true,
                },
                {
                    text = _("Sync automatically"),
                    help_text = _(
                        "Fetch your latest place when a book opens or the device wakes up, and upload it when the book closes or the device sleeps."
                    ),
                    enabled_func = paired,
                    checked_func = function()
                        return s.enabled and s.auto_sync
                    end,
                    callback = function()
                        if not s.enabled then
                            s.enabled = true
                            s.auto_sync = true
                        else
                            s.auto_sync = not s.auto_sync
                        end
                        cloud_sync:save()
                    end,
                },
                {
                    text = _("When another device is behind"),
                    enabled_func = paired,
                    sub_item_table = {
                        {
                            text = _("Ask before going back"),
                            radio = true,
                            checked_func = function()
                                return s.backward ~= "silent"
                            end,
                            callback = function()
                                s.backward = "ask"
                                cloud_sync:save()
                            end,
                        },
                        {
                            text = _("Always go to the latest position"),
                            radio = true,
                            checked_func = function()
                                return s.backward == "silent"
                            end,
                            callback = function()
                                s.backward = "silent"
                                cloud_sync:save()
                            end,
                        },
                    },
                },
                {
                    text_func = function()
                        return T(_("Device name: %1"), s.device_name)
                    end,
                    keep_menu_open = true,
                    callback = function()
                        showRenameDialog(cloud_sync)
                    end,
                    separator = true,
                },
                {
                    text = _("Sign in with user name and password…"),
                    keep_menu_open = true,
                    callback = function()
                        showLoginDialog(plugin, cloud_sync)
                    end,
                },
                {
                    text = _("Pause syncing on this device"),
                    enabled_func = paired,
                    checked_func = function()
                        return paired() and not s.enabled
                    end,
                    callback = function()
                        s.enabled = not s.enabled
                        cloud_sync:save()
                    end,
                },
                {
                    text = _("Disconnect this device"),
                    enabled_func = paired,
                    keep_menu_open = true,
                    callback = function()
                        local ConfirmBox = require("ui/widget/confirmbox")
                        require("ui/uimanager"):show(ConfirmBox:new({
                            text = _("Disconnect this device from the sync server? Your progress on the server is kept."),
                            ok_text = _("Disconnect"),
                            ok_callback = function()
                                cloud_sync:unpair()
                            end,
                        }))
                    end,
                },
            }
        end,
    }
end

return CloudSyncMenu
