local UI = require("wpmui")
local _ = require("gettext")

local wpmutil = require("wpmutil")

-- MARK: Check whether statistics is enabled

local plugins_disabled = wpmutil.readerSetting("plugins_disabled")
if type(plugins_disabled) ~= "table" then
    plugins_disabled = {}
end
if plugins_disabled["statistics"] then
    wpmutil.log_warn("Statistics not enabled")
    UI:showPopup(_("Reading Statistics is not enabled. For please enable to use WPM Statistics."))
    return { disabled = true }
end

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local cache = require("wpmcaching")

local WPM = WidgetContainer:extend{
    name = "wpm_stats",
    is_doc_only = false,
}

function WPM:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function WPM:onDispatcherRegisterActions()
    Dispatcher:registerAction("wpm_stats_action", {category="none", event="ShowAllBooks", title=_("Show WPM Statistics"), general=true,})
    Dispatcher:registerAction("wpm_stats_action", {category="none", event="RefreshCountsHome", title=_("Refresh WPM Stats Page Counts in Home"), general=true,})
    Dispatcher:registerAction("wpm_stats_action", {category="none", event="RefreshCountsWithChooser", title=_("Refresh WPM Stats Page Counts"), general=true,})
end

function WPM:addToMainMenu(menu_items)
    menu_items.wpm_stats = {
        text = _("WPM Statistics"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Show Statistics"),
                callback = function () self:onShowAllBooks() end,
                separator = true,
            },
            {
                text = _("Refresh Pages and Word cound"),
                callback = function () self:onRefreshCountsHome() end,
                hold_callback = function () self:onRefreshCountsWithChooser() end,
            }
        }
    }
end

function WPM:onReaderReady(config)
    local path = config:readSetting("doc_path")
    if path and wpmutil.isInHome(path) then
        cache.storeFilepath(path, config:readSetting("partial_md5_checksum"))
    end
end


-- MARK: Refreshing Book Count

function WPM:onRefreshCountsHome() cache.storeDir() end
function WPM:onRefreshCountsWithChooser() cache.storeDir(true) end


-- Shows all books in a list.
function WPM:onShowAllBooks()
    UI:showBooks()
end

return WPM
