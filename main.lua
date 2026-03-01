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
local Device = require("device")
local Dispatcher = require("dispatcher")  -- luacheck:ignore
local DocSettings = require("docsettings")
local DocumentRegistry = require("document/documentregistry")
local KeyValuePage = require("ui/widget/keyvaluepage")
local ReaderUI = require("apps/reader/readerui")
local SQ3 = require("lua-ljsqlite3/init")
local WidgetContainer = require("ui/widget/container/widgetcontainer")

local datetime = require("datetime")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local partialMD5 = require("util").partialMD5
local wpm_settings = require("luasettings"):open(DataStorage:getSettingsDir().."/wpm_statistics.lua")


-- MARK: Word and Page management

-- This is mostly copied from https://github.com/joshuacant/ProjectTitle/blob/afb9d84d3b47488cd728c9d990b2f76bab1b5447/bookinfomanager.lua#L518
-- Adjusted to also parse the word count
local function getPageFromFilename(filepath)
    local filename_without_suffix, filetype = filemanagerutil.splitFileNameType(filepath)
    local fn_pagecount = tonumber(string.match(filename_without_suffix, "P%((%d+)%)"))
    local fn_wordcount = tonumber(string.match(filename_without_suffix, "W%((%d+)%)"))
    return fn_pagecount, fn_wordcount, filetype
end

local function getPageCount(filepath)
    local provider = ReaderUI:extendProvider(filepath, DocumentRegistry:getProvider(filepath))
    local document = DocumentRegistry:openDocument(filepath, provider)
    local loaded = true
    local pages = nil
    local words = nil
    if document then
        if document.loadDocument then                -- needed for crengine
            if document:loadDocument(false) then     -- load only metadata
                -- for credocument, number of pages returned by document:getPageCount() is wrong
                -- so instead, try finding pagecount in filename or calibre metadata
                local function getEstimatedCounts(fname)
                    local pagecount, wordcount, filetype = getPageFromFilename(fname)

                    if pagecount and pagecount > 0 then
                        logger.dbg(logprefix, "Pagecount found in filename", filepath, pagecount)
                        pages = pagecount
                        words = wordcount or 0
                    end

                    if filetype ~= "epub" then
                        logger.dbg(logprefix, "Skipping pagecount, not epub", fname)
                        return nil
                    end

                    local opf_file = nil
                    local locate_opf_command = "unzip " .. "-lqq \"" .. fname .. "\" \"*.opf\""
                    local opf_match_pattern = "(%S+%.opf)$"
                    local line = ""

                    if Device:isAndroid() then
                        -- fh style for Android
                        local fh = io.popen(locate_opf_command, "r")
                        while true and fh ~= nil do
                            line = fh:read()
                            if line == nil or opf_file ~= nil then
                                break
                            end
                            opf_file = string.match(line, opf_match_pattern)
                            logger.dbg(logprefix, line)
                        end
                    else
                        -- std_out style for POSIX
                        local std_out = nil
                        std_out = io.popen("unzip " .. "-lqq \"" .. fname .. "\" \"*.opf\"")
                        if std_out then
                            line = std_out:read()
                            opf_file = string.match(line, opf_match_pattern)
                            logger.dbg(logprefix, line)
                            std_out:close()
                        end
                    end

                    if opf_file then
                        local expand_opf_command = "unzip " .. "-p \"" .. fname .. "\" " .. "\"" .. opf_file .. "\""
                        local found_pages = nil
                        local found_pagev = nil
                        local do_break_p = false
                        local found_words = nil
                        local found_wordv = nil
                        local do_break_w = false

                        local function parse_opf_file(x, fp, fv, l)
                            if fp then
                                -- multiline format, keep looking for the #values# line
                                fv = string.match(l, "\"#value#\": (%d+),")
                                if fv then
                                    return fp, fv, true
                                end
                                -- why category_sort? because it's always there and the props are stored alphabetically
                                -- so if we reach that before finding #value# it means there isn't one, which can happen
                                if string.match(l, "\"category_sort\":") then
                                    return fp, fv, true
                                end
                            else
                                fp = string.match(l, "user_metadata:#" .. x) or string.match(l, "\"#" .. x .. "\"")
                                -- check for single line format
                                -- only look for a numerical value if #pages is found
                                if fp then
                                    fv = string.match(l, "&quot;#value#&quot;: (%d+),")
                                end
                                if fv then
                                    return fp, fv, true
                                end
                            end
                            return fp, fv, false
                        end

                        local function checkLine(line)
                            if not do_break_p then
                                found_pages, found_pagev, do_break_p = parse_opf_file("pages", found_pages, found_pagev, line)
                            end
                            if not do_break_w then
                                found_words, found_wordv, do_break_w = parse_opf_file("words", found_words, found_wordv, line)
                            end
                            return do_break_p and do_break_w
                        end

                        if Device:isAndroid() then
                            -- fh style for Android
                            local fh = io.popen(expand_opf_command, "r")
                            while true and fh ~= nil do
                                line = fh:read()
                                if line == nil then
                                    break
                                end
                                if checkLine(line) then
                                    break
                                end
                            end
                        else
                            -- std_out style for POSIX
                            local std_out = io.popen(expand_opf_command)
                            if std_out then
                                for std_line in std_out:lines() do
                                    if checkLine(std_line) then
                                        break
                                    end
                                end
                                std_out:close()
                            end
                        end
                        local pages = nil
                        local words = nil
                        if found_pagev and found_pagev ~= "0" then
                            logger.dbg(logprefix, "Pagecount found in opf metadata ", fname, found_pagev)
                            pages = tonumber(found_pagev)
                        end
                        if found_wordv and found_wordv ~= "0" then
                            logger.dbg(logprefix, "Wordcount found in opf metadata ", fname, found_wordv)
                            words = tonumber(found_wordv)
                        end
                        if pages or words then
                            return pages, words
                        end
                    end
                    logger.dbg(logprefix, "Page/Wordcount not found", fname)
                    return nil
                end
                local success, response, wordResponse = pcall(getEstimatedCounts, filepath)
                if success then
                    pages = response
                    words = wordResponse
                end
            end
        else
            -- for all others than crengine, we seem to get an accurate nb of pages
            local pagecount, wordcount = getPageFromFilename(filepath)
            pages = pagecount or document:getPageCount()
            words = wordcount or 0 -- cannot get word count from metadata
        end
    end
    return pages, words
end

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

-- Get and update the cache for the given path and hash.
local function updateCache(path, hash, force, noFlush)
    local old_hash = wpm_settings:readSetting(path)
    if old_hash and old_hash ~= hash then
        wpm_settings:delSetting(old_hash)
        force = true
    end
    local settings = getCache(hash)
    if force or not settings or not settings.pages or not settings.words then
        local pages, words = getPageCount(path)
        settings = {path = path, pages = pages, words = words}
        wpm_settings:saveSetting(hash, settings)
        wpm_settings:saveSetting(path, hash)
        if not noFlush then
            wpm_settings:flush()
        end
    end

    return settings
end

-- MARK: Set up patching (To get page/word counts)

local patched_coverbrowser = false
local function patchCoverBrowser()
    if not patched_coverbrowser then
        patched_coverbrowser = true


        local BookInfoManager = require("bookinfomanager")

        -- Extract Page/Word Count when extracting information for one file
        -- This is executed when one file will be manually refreshed
        local orig_delete = BookInfoManager.deleteBookInfo
        function BookInfoManager:deleteBookInfo(filepath)
            updateCache(filepath, getHash(filepath), true)
            return orig_delete(self, filepath)
        end


        -- Extract Page/Word Count when extracting information for multiple files
        -- This is executed when one folder will be refreshed

        -- Extract is called in a subprocess so it needs to write extracted files in a file
        local cache_file = DataStorage:getDataDir() .. "/cache/wpm_stats_refresh"
        local orig_extract = BookInfoManager.extractBookInfo
        function BookInfoManager:extractBookInfo(filepath, cover_specs)
            local file = io.open(cache_file, "a")
            if file then
                file:write(filepath .. "\n")
                file:close()
            end

            return orig_extract(self, filepath, cover_specs)
        end

        -- This is called in the main process. It will the call extractBookInfo in a subprocess.
        -- This clears the cache file and reads what extractBookInfo has written in the meantime and then save the page/word counts.
        local orig_extractAll = BookInfoManager.extractBooksInDirectory
        function BookInfoManager:extractBooksInDirectory(path, cover_specs)
            os.remove(cache_file)

            local ret = orig_extractAll(self, path, cover_specs)

            local file = io.open(cache_file, "r")
            if file then
                for filepath in file:lines() do
                    updateCache(filepath, getHash(filepath), true, true)
                end
                file:close()
            end

            wpm_settings:flush()
            os.remove(cache_file)

            return ret
        end
    end
end
require("userpatch").registerPatchPluginFunc("coverbrowser", patchCoverBrowser)


-- Extract the page/word count when the book is closed (.sdr is written)
-- This only will fetch the info if it doesn't exist yet.
local orig_flush = DocSettings.flush
function DocSettings:flush(data)
    local ok = orig_flush(self, data)
    if ok then
        data = data or self.data
        if data and data.doc_path and data.partial_md5_checksum then
            updateCache(data.doc_path, data.partial_md5_checksum)
        end
    end
    return ok
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
end

function WPM:addToMainMenu(menu_items)
    menu_items.wpm_stats = {
        text = _("WPM Statistics"),
        sorting_hint = "tools",
        callback = function () self:onShowAllBooks() end,
    }
end

local function query(sql_statement)
    local db_location = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local conn = SQ3.open(db_location)
    local result = conn:exec(sql_statement)
    conn:close()
    return result
end

-- Shows all books in a list.
function WPM:onShowAllBooks()
    local sql_books = query([[
    SELECT
        id AS id,
        title as title,
        md5 AS md5,
        total_read_time AS time,
        total_read_pages * 1.0 / pages AS progress
    FROM book
    WHERE total_read_pages > 0 AND total_read_time > 0;
    ]])
    local books = {}
    local l = 1
    for i = 1, #sql_books do
        local book = { id = sql_books[1][i], title = sql_books[2][i], hash = sql_books[3][i]}
        book["settings"] = getCache(book.hash)
        local has_data = false
        if book.settings then
            local min = tonumber(sql_books[4][i]) / 60
            local per = tonumber(sql_books[5][i])
            if book.settings.pages and book.settings.pages > 0 then
                local pages = book.settings.pages * per
                book["ppm"] = string.format("%.1f PPM", pages / min)
                book["mpp"] =   datetime.secondsToClockDuration("classic", min * 60 / pages):gsub("^00?:0?(%d?%d:%d%d)$", "%1") .. " per page"
                has_data = true
            end
            if book.settings.words and book.settings.words > 0 then
                book["wpm"] = string.format("%.1f WPM", (book.settings.words * per) / min)
                has_data = true
            end
        end

        local callback = has_data and function () self:showDetails(book) end
        books[l] = {book.title, datetime.secondsToClockDuration(G_reader_settings:readSetting("duration_format"), sql_books[4][i], true), callback = callback}
        books[l+1] = {"", (book.wpm or "") .. "  " .. (book.mpp or "") .. "  " .. (book.ppm or ""), callback = callback}
        books[l+2] = "---"
        l = l + 3
    end
    present(
        KeyValuePage:new{
            title = _("All books"),
            kv_pairs = books,
            value_align = "right",
            single_page = true,
        }
    )
end


-- Shows the detailed overview for the given book in a list.
function WPM:showDetails(book)
    -- TODO: Show correct details
    local kv = self.kv
    local details = {
        {"first", "abc"},
    }
    present(
        KeyValuePage:new{
            title = book.title,
            kv_pairs = details,
            value_align = "right",
            single_page = true,
            callback_return = function() present(kv) end,
            close_callback = function() self.kv = nil end,
        }
    )
end

return WPM
