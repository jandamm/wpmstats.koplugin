local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local logger = require("logger")
local logprefix = "WPM Stats - "


-- MARK: Check whether statistics is enabled

local plugins_disabled = G_reader_settings:readSetting("plugins_disabled")
if type(plugins_disabled) ~= "table" then
    plugins_disabled = {}
end
if plugins_disabled["statistics"] then
    logger.warn(logprefix, "Statistics not enabled")
    local popup = InfoMessage:new{
        text = _("Reading Statistics is not enabled. For please enable to use WPM Statistics."),
    }
    UIManager:show(popup)
    return { disabled = true }
end

local Dispatcher = require("dispatcher")  -- luacheck:ignore
local DocSettings = require("docsettings")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local UI = require("wpmui")
local cache = require("wpmcaching")

-- MARK: Set up patching (To get page/word counts)

-- Extract the page/word count when the book is closed (.sdr is written)
-- This only will fetch the info if it doesn't exist yet.
local orig_open = DocSettings.open
function DocSettings:open(path, ...)
    local new = orig_open(self, path, ...)
    if path then
        cache:storeFilepath(path)
    end
    return new
end

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


-- MARK: Refreshing Book Count

function WPM:onRefreshCountsHome() cache:storeDir() end
function WPM:onRefreshCountsWithChooser() cache:storeDir(true) end


-- Shows all books in a list.
function WPM:onShowAllBooks()
    UI:showBooks()
end

return WPM
