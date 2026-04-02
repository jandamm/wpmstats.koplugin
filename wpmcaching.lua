local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local UI = require("wpmui")
local _ = require("gettext")

local filemanagerutil = require("apps/filemanager/filemanagerutil")
local getPageCount = require("wpmpagecount")
local util = require("util")
local wpmutil = require("wpmutil")
local partialMD5 = util.partialMD5
local wpm_settings = require("luasettings"):open(DataStorage:getSettingsDir().."/wpm_statistics.lua")

local M = {}

-- Gets the filehash
local function getHash(filepath)
    local hash
    local sidecar_file = DocSettings:findSidecarFile(filepath)
    if sidecar_file then
        hash = DocSettings.openSettingsFile(sidecar_file):readSetting("partial_md5_checksum")
    end
    return hash or partialMD5(filepath)
end

-- Cleans and gets prefs if the books hash changed
local function checkOldHash(hash, path)
    local old_hash = wpm_settings:readSetting(path)
    if old_hash and old_hash ~= hash then
        local old_book = wpm_settings:readSetting(old_hash)
        if old_book then
            wpm_settings:delSetting(old_hash)
            return true, old_book.prefs
        end
    end
end

local Migration140 = {}
function Migration140.migrate(book)
    if book and book.ignored then
        book.prefs = book.prefs or {}
        book.prefs.overallStatsIgnored = book.prefs.overallStatsIgnored or book.ignored
        book.ignored = nil
    end
    return book
end

local function getBookRaw(hash, default)
    local book = wpm_settings:readSetting(hash)
    book = Migration140.migrate(book)
    return book or default
end

local function storeBook(hash, book)
    wpm_settings:saveSetting(hash, book)
    if book.path then
        wpm_settings:saveSetting(book.path, hash)
    end
end

-- Migrates the path of the book when the book is moved.
local function migratePath(hash, path)
    local book = wpm_settings:readSetting(hash)
    if book and book.path and book.path ~= path then
        wpm_settings:delSetting(book.path)
        book.path = path
        storeBook(hash, book)
        return true
    end
end

-- Fixes a bug where getBook with enriching would save pages into prefs and words into pages.
local BugFix141 = {}
function BugFix141.fixPrefs(prefs)
    return type(prefs) ~= "number" and prefs or nil
end

local function storeBookData(hash, path, prefs, pages, words)
    prefs = prefs or getBookRaw(hash, {}).prefs
    prefs = BugFix141.fixPrefs(prefs)
    local book = {path = path, pages = pages, words = words, prefs = prefs}
    storeBook(hash, book)
    return book
end

function BugFix141.fixBook(hash, book)
    if book and type(book.prefs) == "number" then
        book = storeBookData(hash, book.path, book.prefs, book.prefs, book.pages)
        wpm_settings:flush()
    end
    return book
end

-- Get the saved settings for the given hash.
-- Unfortunately the Reading Statistics db doesn't include a path.
-- So this will only return values when the book was opened (and .sdr was written) or metadata extracted.
function M.getBook(hash, enriched)
    local book = getBookRaw(hash)
    book = BugFix141.fixBook(hash, book)
    if book then
        book.prefs = book.prefs or {} -- Ensure prefs
    end
    if enriched and book and book.path and (not book.pages or not book.words) then
        local pages, words = getPageCount(book.path)
        book = storeBookData(hash, book.path, book.prefs, pages, words)
        wpm_settings:flush()
    end
    return book
end

local function updatePrefs(hash, update)
    local book = getBookRaw(hash)
    if not book then return end
    book.prefs = book.prefs or {}
    update(book.prefs)
    storeBook(hash, book)
    wpm_settings:flush()
end

function M.setOffset(hash, offset)
    updatePrefs(hash, function(prefs)
        prefs.progressOffset = offset
    end)
end

function M.toggleIgnore(hash)
    updatePrefs(hash, function(prefs)
        if prefs.overallStatsIgnored then
            prefs.overallStatsIgnored = nil
        else
            prefs.overallStatsIgnored = true
        end
    end)
end

-- Stores the filpath for the given hash
function M.storeFilepath(path, hash)
    hash = hash or getHash(path)
    local new_hash, prefs = checkOldHash(hash, path)
    local migrated = migratePath(hash, path)
    if not M.getBook(hash) then -- new book
        storeBookData(hash, path, prefs)
        wpm_settings:flush()
    elseif new_hash or migrated then
        wpm_settings:flush()
    end
end

function M.purge()
    wpm_settings:reset({})
    wpm_settings:purge()
end

function M.chooseDirToStoreDir()
    local PathChooser = require("ui/widget/pathchooser")
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = false,
        file_filter = false,
        path = wpmutil.homeDir(),
        onConfirm = M.storeDir,
    }
    UI:show(path_chooser)
end

function M.storeDir(dir)
    UI:showPopup(_("Refreshing page and word counts"), { dismissable = false })
    UI:refresh()

    dir = dir or wpmutil.homeDir()

    util.findFiles(dir, function(path)
        local filename, filetype = filemanagerutil.splitFileNameType(path)
        if filename == "" or filename:find(".", 1, true) == 1 then return end -- Ignore hidden files
        if filetype == "epub" or filetype == "pdf" then
            local hash = getHash(path)
            local _, prefs = checkOldHash(hash, path)
            migratePath(hash, path)
            local pages, words = getPageCount(path)
            storeBookData(hash, path, prefs, pages, words)
        end
    end, true)
    wpm_settings:flush()

    UI:dismissPopup()
end

return M
