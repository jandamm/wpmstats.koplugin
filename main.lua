local UI = require("wpmui")
local _ = require("gettext")

local wpmutil = require("wpmutil")

-- MARK: Check whether statistics is enabled

local plugins_disabled = wpmutil.readerSetting("plugins_disabled")
if type(plugins_disabled) ~= "table" then
    plugins_disabled = {}
end
-- Cannot work without Reading Statistics
if plugins_disabled["statistics"] then
    wpmutil.log.warn("Statistics plugin not enabled")
    UI:showPopup(_("Reading Statistics is not enabled. For please enable to use WPM Statistics."))
    return { disabled = true }
end

-- Won't get any new data without Reading Statistics being enabled
-- Can still work since there is probably some data...
if not wpmutil.readerSettingSafe("statistics").is_enabled then
    wpmutil.log.warn("Statistics not enabled")
    UI:showPopup(_("Reading Statistics is disabled. WPM Statistics won't get any new data until it's enabled again."))
end
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local cache = require("wpmcaching")

local WPM = WidgetContainer:extend{
    name = "wpm_stats",
    is_doc_only = false,
}

local DEFAULT_DURATION_SHORT_BOOKS = 300
local default_settings = {
    duration_short_books = DEFAULT_DURATION_SHORT_BOOKS,
    recalculate_book_stats = true,
}

function WPM:init()
    -- G_reader_settings:delSetting(self.name) -- DEBUG
    self.settings = wpmutil.insertFallbackValues(
        wpmutil.readerSetting(self.name, default_settings),
        default_settings
    )
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    self:addToFileManager()
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
                text = _("Settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            if self.settings.duration_short_books == 0 then
                                return _("Ignore short read books")
                            end
                            return string.format(_("Ignore book read less than %d minutes"), wpmutil.math.secondsToMinutes(self.settings.duration_short_books))
                        end,
                        checked_func = function () return self.settings.duration_short_books > 0 end,
                        callback = function(instance)
                            local SpinWidget = require("ui/widget/spinwidget")
                            UI:show(SpinWidget:new{
                                value = self.settings.duration_short_books,
                                value_min = 0,
                                value_max = 3600, -- 1 hour
                                default_value  = DEFAULT_DURATION_SHORT_BOOKS,
                                value_step = 60, -- 1 minute
                                value_hold_step = 300, -- 5 minutes
                                unit = "s",
                                title_text =  _("Minimum book read duration"),
                                info_text = _("Set the minimum duration a book needs to be read to be evaluated.\n\nThe fewer pages are read, the less precise the WPM calculation is."),
                                option_text = _("Disable"),
                                option_callback = function() self.settings.duration_short_books = 0 end,
                                ok_text = _("Set"),
                                callback = function(spin) self.settings.duration_short_books = spin.value end,
                                close_callback = function() instance:updateItems() end,
                            })
                        end,
                        hold_callback = function (instance)
                            if self.settings.duration_short_books > 0 then
                                self.duration_short_books = self.settings.duration_short_books -- Keep toggle value until KOReader restarts
                                self.settings.duration_short_books = 0
                            else
                                self.settings.duration_short_books = self.duration_short_books or DEFAULT_DURATION_SHORT_BOOKS
                            end
                            instance:updateItems()
                        end,
                    },
                    {
                        text = _("Hide short read books"),
                        checked_func = function () return self.settings.duration_short_books > 0 and self.settings.hide_short_books end,
                        enabled_func = function () return self.settings.duration_short_books > 0 end,
                        callback = function () self.settings.hide_short_books = not self.settings.hide_short_books end,
                        separator = true,
                    },
                    {
                        text = _("Recalculate book stats"),
                        checked_func = function () return self.settings.recalculate_book_stats end,
                        callback = function () self.settings.recalculate_book_stats = not self.settings.recalculate_book_stats end,
                        hold_callback = function () UI:showPopup(_("Reading Statistics calculates the number of distict pages you visited as progress. So it might be that you progressed four pages but it will be counted as six pages because you visited footnotes, a map, glossary or changed font size.\n\nThis plugin uses the progress made from the first page opened that day till the last visited page. Which is more precise when reading a book from start to finish.\n\nEnabling will adjust the overall stats to this plugins calculation when showing details for a book.")) end,
                        separator = true,
                    },
                    {
                        text = _("Page count cache"),
                        sub_item_table = {
                            {
                                text = _("Cache home dir"),
                                callback = function () self:onRefreshCountsHome() end,
                            },
                            {
                                text = _("Cache folder ..."),
                                callback = function () self:onRefreshCountsWithChooser() end,
                                separator = true,
                            },
                            {
                                text = _("Clear cache"),
                                callback = function () cache.purge() end,
                                keep_menu_open = true,
                            }
                        },
                    }
                }
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


function WPM:addToFileManager()
    local FileManager = require("apps/filemanager/filemanager")

    FileManager.addFileDialogButtons(FileManager, "wpmstats", function (folder, is_file)
        if is_file then return nil end
        return {
            {
                text = _("Cache for WPM Stats"),
                callback = function()
                    local dialog = UI:getTopVisibleWidget()
                    if dialog then UI:close(dialog) end
                    cache.storeDir(folder)
                end,
            },
        }
    end
)
end

-- MARK: Refreshing Book Count

function WPM:onRefreshCountsHome() cache.storeDir() end
function WPM:onRefreshCountsWithChooser() cache.chooseDirToStoreDir() end


-- Shows all books in a list.
function WPM:onShowAllBooks()
    UI:showBooks(self.settings)
end

return WPM
