local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local SQ3 = require("lua-ljsqlite3/init")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local datetime = require("datetime")
local wpmutil = require("wpmutil")

local function sql_query(sql_statement)
    local db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn = SQ3.open(db_location)
    local result = conn:exec(sql_statement)
    conn:close()
    return result
end

-- sql_result needs to have duration and progress
local function formatStats(book, sql_result, row)
    if book.cache then
        local duration = tonumber(sql_result.duration[row]) or 0
        local progress = tonumber(sql_result.progress[row]) or 0
        if duration == 0 or progress <= 0 then
            return _("No progress.")
        end
        local min = duration / 60
        local avg = {}
        if book.cache.words and book.cache.words > 0 then
            table.insert(avg, string.format("%.1f WPM", (book.cache.words * progress) / min))
        end
        if book.cache.pages and book.cache.pages > 0 then
            local pages = book.cache.pages * progress
            table.insert(avg, datetime.secondsToClockDuration("classic", duration / pages):gsub("^00?:0?(%d?%d:%d%d)$", "%1") .. "/page")
        end
        if #avg > 0 then
            return table.concat(avg, "  ")
        end
    end
end

local function userDate(duration, withoutSeconds)
    return datetime.secondsToClockDuration(wpmutil.readerSetting("duration_format"), duration, withoutSeconds)
end

local M = {}

function M:show(view)
    UIManager:show(view)
end

function M:refresh()
    UIManager:forceRePaint()
end

function M:showPopup(text, args)
    args = args or {}
    args["text"] = text
    self.popup = InfoMessage:new(args)
    self:show(self.popup)
    return self.popup
end

function M:dismissPopup(popup)
    popup = popup or self.popup
    if popup then
        UIManager:close(popup)
        if popup == self.popup then
            self.popup = nil
        end
    end
end

function M:presentKV(kv)
    self.kv = kv
    self:show(self.kv)
end


-- Shows all books in a list.
function M:showBooks()
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
                self:showPopup(_("Books with less than 5 minutes reading time are ignored."))
            end
            books[l] = {sql_books.title[i], "< " .. userDate(300), callback = cb}
            books[l+1] = "---"
            l = l + 2
        else
            local book = { id = sql_books.id[i], title = sql_books.title[i], hash = sql_books.hash[i]}

            local cache = require("wpmcaching")
            book["cache"] = cache.getBook(book.hash, true)
            book["avg"] = formatStats(book, sql_books, i)

            local callback = book.avg and function () self:showDetails(book) end
            books[l] = {book.title, userDate(tonumber(sql_books.duration[i])), callback = callback}
            books[l+1] = {"", book.avg or _("No word and page count. Please refresh metadata."), callback = callback}
            books[l+2] = "---"
            l = l + 3
        end
    end
    self:presentKV(
        KeyValuePage:new{
            title = _("All books"),
            kv_pairs = books,
            value_align = "right",
            single_page = false,
        }
    )
end


-- Shows the detailed overview for the given book in a list.
function M:showDetails(book)
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
    self:presentKV(
        KeyValuePage:new{
            title = book.title,
            kv_pairs = details,
            value_align = "right",
            single_page = false,
            callback_return = function() self:presentKV(kv) end,
            close_callback = function() self.kv = nil end,
        }
    )
end

return M
