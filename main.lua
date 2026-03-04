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

local DataStorage = require("datastorage")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local DocSettings = require("docsettings")
local KeyValuePage = require("ui/widget/keyvaluepage")
local SQ3 = require("lua-ljsqlite3/init")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local datetime = require("datetime")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local util = require("util")
local partialMD5 = util.partialMD5
local wpm_settings = require("luasettings"):open(DataStorage:getSettingsDir().."/wpm_statistics.lua")


-- MARK: Word and Page management

local getPageCount = require("pagecount")

-- Gets the filehash
local function getHash(filepath)
    local hash
    local sidecar_file = DocSettings:findSidecarFile(filepath)
    if sidecar_file then
        hash = DocSettings.openSettingsFile(sidecar_file):readSetting("partial_md5_checksum")
    end
    return hash or partialMD5(filepath)
end

-- Get the saved settings for the given hash.
-- Unfortunately the Reading Statistics db doesn't include a path.
-- So this will only return values when the book was opened (and .sdr was written) or metadata extracted.
local function getCache(hash)
    return wpm_settings:readSetting(hash)
end

local function cacheFile(path, update)
    local hash = getHash(path)
    local force = update ~= true

    -- clean up old caches
    local old_hash = wpm_settings:readSetting(path)
    if old_hash and old_hash ~= hash then
        wpm_settings:delSetting(old_hash)
        force = true
    end

    -- Update
    local settings = force and nil or getCache(hash) -- No settings if force
    if not settings or not settings.pages or not settings.words then
        local pages, words = getPageCount(path)
        settings = {path = path, pages = pages, words = words}
        wpm_settings:saveSetting(hash, settings)
        wpm_settings:saveSetting(path, hash)
        if update then
            wpm_settings:flush() -- If no update everything will be flushed at the end
        end
    end
end


-- MARK: Set up patching (To get page/word counts)

-- Extract the page/word count when the book is closed (.sdr is written)
-- This only will fetch the info if it doesn't exist yet.
local orig_open = DocSettings.open
function DocSettings:open(path, ...)
    local new = orig_open(self, path, ...)
    if path then
        cacheFile(path, true)
    end
    return new
end

local WPM = WidgetContainer:extend{
    name = "wpm_stats",
    is_doc_only = false,
}

local function present(kv)
    WPM.kv = kv
    UIManager:show(WPM.kv)
end

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

local function cacheFileIfBook(path)
    local filename, filetype = filemanagerutil.splitFileNameType(path)
    if filename:find(".", 1, true) == 1 then return end -- Ignore hidden files
    if filetype == "epub" or filetype == "pdf" then
        cacheFile(path)
    end
end

local function cacheDir(dir)
    dir = dir or G_reader_settings:readSetting("home_dir")

    UIManager:forceRePaint()

    local msg = InfoMessage:new{ text = _("Refreshing page and word counts"), dismissable = false }
    UIManager:show(msg)
    UIManager:forceRePaint()

    util.findFiles(dir, cacheFileIfBook, true)
    wpm_settings:flush()

    UIManager:close(msg)
end

function WPM:onRefreshCountsHome() cacheDir() end
function WPM:onRefreshCountsWithChooser()
    local home = G_reader_settings:readSetting("home_dir")
    local PathChooser = require("ui/widget/pathchooser")
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = false,
        file_filter = false,
        path = home,
        onConfirm = cacheDir,
    }
    UIManager:show(path_chooser)
end


-- MARK: UI

local function sql_query(sql_statement)
    local db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn = SQ3.open(db_location)
    local result = conn:exec(sql_statement)
    conn:close()
    return result
end

-- sql_result needs to have duration and progress
local function formatStats(book, sql_result, row)
    if book.settings then
        local duration = tonumber(sql_result.duration[row]) or 0
        local progress = tonumber(sql_result.progress[row]) or 0
        if duration == 0 or progress <= 0 then
            return _("No progress.")
        end
        local min = duration / 60
        local avg = {}
        if book.settings.words and book.settings.words > 0 then
            table.insert(avg, string.format("%.1f WPM", (book.settings.words * progress) / min))
        end
        if book.settings.pages and book.settings.pages > 0 then
            local pages = book.settings.pages * progress
            table.insert(avg, datetime.secondsToClockDuration("classic", duration / pages):gsub("^00?:0?(%d?%d:%d%d)$", "%1") .. "/page")
            table.insert(avg, string.format("%.1f PPM", pages / min))
        end
        return table.concat(avg, "  ")
    end
end

local function userDate(duration, withoutSeconds)
    return datetime.secondsToClockDuration(G_reader_settings:readSetting("duration_format"), duration, withoutSeconds)
end

-- Shows all books in a list.
function WPM:onShowAllBooks()
    local sql_books = sql_query([[
    SELECT
        id AS id,
        title AS title,
        md5 AS hash,
        total_read_time AS duration,
        total_read_pages * 1.0 / pages AS progress
    FROM book
    WHERE total_read_pages > 0 AND total_read_time > 0
    ORDER BY last_open DESC;
    ]])
    local books = {}
    local l = 1
    for i = 1, #sql_books.duration do
        if sql_books.duration[i] < 300 then
            local cb = function ()
                UIManager:show(InfoMessage:new{ text = _("Books with less than 5 minutes reading time are ignored.") })
            end
            books[l] = {sql_books.title[i], "< " .. userDate(300), callback = cb}
            books[l+1] = "---"
            l = l + 2
        else
            local book = { id = sql_books.id[i], title = sql_books.title[i], hash = sql_books.hash[i]}

            book["settings"] = getCache(book.hash)
            book["avg"] = formatStats(book, sql_books, i)

            local callback = book.avg and function () self:showDetails(book) end
            books[l] = {book.title, userDate(tonumber(sql_books.duration[i])), callback = callback}
            books[l+1] = {"", book.avg or _("No word and page count. Please refresh metadata."), callback = callback}
            books[l+2] = "---"
            l = l + 3
        end
    end
    present(
        KeyValuePage:new{
            title = _("All books"),
            kv_pairs = books,
            value_align = "right",
            single_page = false,
        }
    )
end


-- Shows the detailed overview for the given book in a list.
function WPM:showDetails(book)
    local sql_stmt = [[
    SELECT
        sum(ps.duration) AS duration,
        (
            SELECT (page * 1.0 / total_pages)
            FROM page_stat_data ps2
            WHERE ps2.id_book = ps.id_book AND date(ps2.start_time, 'unixepoch', 'localtime') = date(ps.start_time, 'unixepoch', 'localtime')
            ORDER BY ps2.start_time DESC
            LIMIT 1
        ) - (
            SELECT (page * 1.0 / total_pages)
            FROM page_stat_data ps2
            WHERE ps2.id_book = ps.id_book AND date(ps2.start_time, 'unixepoch', 'localtime') = date(ps.start_time, 'unixepoch', 'localtime')
            ORDER BY ps2.start_time ASC
            LIMIT 1
        ) AS progress,
        date(ps.start_time, 'unixepoch', 'localtime') AS id
    FROM page_stat_data ps
    WHERE ps.id_book = %d
    GROUP BY date(ps.start_time, 'unixepoch', 'localtime')
    ORDER BY id DESC;
    ]]

    local sql_book = sql_query(string.format(sql_stmt, book.id))
    local kv = self.kv
    local details = {
        {_("Average"), book.avg},
        "---",
    }
    local l = 3
    for i = 1, #sql_book.duration do
        local stats = formatStats(book, sql_book, i)
        if stats then
            details[l] = {sql_book.id[i], formatStats(book, sql_book, i)}
            l = l + 1
        end
    end
    present(
        KeyValuePage:new{
            title = book.title,
            kv_pairs = details,
            value_align = "right",
            single_page = false,
            callback_return = function() present(kv) end,
            close_callback = function() self.kv = nil end,
        }
    )
end

return WPM
