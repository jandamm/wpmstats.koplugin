local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local filemanagerutil = require("apps/filemanager/filemanagerutil")
local getPageCount = require("wpmpagecount")
local util = require("util")
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

-- Cleans if the old hash on change
local function cleanStaleHash(path, hash)
    local old_hash = wpm_settings:readSetting(path)
    if old_hash and old_hash ~= hash then
        wpm_settings:delSetting(old_hash)
        return true
    end
end

local function storeBook(hash, path, pages, words)
    local book = {path = path, pages = pages, words = words}
    wpm_settings:saveSetting(hash, book)
    wpm_settings:saveSetting(path, hash)
    return book
end

-- Get the saved settings for the given hash.
-- Unfortunately the Reading Statistics db doesn't include a path.
-- So this will only return values when the book was opened (and .sdr was written) or metadata extracted.
function M:getBook(hash, enriched)
    local book = wpm_settings:readSetting(hash)
    if enriched and book and book.path and (not book.pages or not book.words) then
        local pages, words = getPageCount(book.path)
        book = storeBook(hash, book.path, pages, words)
        wpm_settings:flush()
    end
    return book
end

-- Stores the filpath for the given hash
function M:storeFilepath(path)
    local hash = getHash(path)
    local flush = cleanStaleHash(path, hash)
    if not self:getBook(hash) then
        storeBook(hash, path)
        flush = true
    end
    if flush then
        wpm_settings:flush()
    end
end

function M:storeDir(dir)
    dir = dir or G_reader_settings:readSetting("home_dir")

    UIManager:forceRePaint()

    local msg = InfoMessage:new{ text = _("Refreshing page and word counts"), dismissable = false }
    UIManager:show(msg)
    UIManager:forceRePaint()

    util.findFiles(dir, function(path)
        local filename, filetype = filemanagerutil.splitFileNameType(path)
        if filename == "" or filename:find(".", 1, true) == 1 then return end -- Ignore hidden files
        if filetype == "epub" or filetype == "pdf" then
            local hash = getHash(path)
            cleanStaleHash(path, hash)
            local pages, words = getPageCount(path)
            storeBook(hash, path, pages, words)
        end
    end, true)
    wpm_settings:flush()

    UIManager:close(msg)
end

return M
