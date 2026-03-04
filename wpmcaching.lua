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

-- Get the saved settings for the given hash.
-- Unfortunately the Reading Statistics db doesn't include a path.
-- So this will only return values when the book was opened (and .sdr was written) or metadata extracted.
function M:getBook(hash)
    return wpm_settings:readSetting(hash)
end

function M:storeFile(path, update)
    local hash = getHash(path)
    local force = update ~= true

    -- clean up old caches
    local old_hash = wpm_settings:readSetting(path)
    if old_hash and old_hash ~= hash then
        wpm_settings:delSetting(old_hash)
        force = true
    end

    -- Update
    local settings = force and nil or self:getBook(hash) -- No settings if force
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

function M:storeDir(dir)
    dir = dir or G_reader_settings:readSetting("home_dir")

    UIManager:forceRePaint()

    local msg = InfoMessage:new{ text = _("Refreshing page and word counts"), dismissable = false }
    UIManager:show(msg)
    UIManager:forceRePaint()

    local function storeIfBook(path)
        local filename, filetype = filemanagerutil.splitFileNameType(path)
        if filename == "" or filename:find(".", 1, true) == 1 then return end -- Ignore hidden files
        if filetype == "epub" or filetype == "pdf" then
            self:storeFile(path)
        end
    end
    util.findFiles(dir, storeIfBook, true)
    wpm_settings:flush()

    UIManager:close(msg)
end

return M
