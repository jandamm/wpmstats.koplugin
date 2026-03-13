local util = require("util")

local M = {}

local logprefix = "WPM Stats - "
local logger = require("logger")

function M.log_warn(...)
    logger.warn(logprefix, ...)
end
function M.log_dbg(...)
    logger.dbg(logprefix, ...)
end

function M.readerSetting(setting)
    return G_reader_settings:readSetting(setting)
end

function M.readerSettingSafe(setting)
    return G_reader_settings:has(setting) and M.readerSetting(setting) or {}
end

function M.home()
    return M.readerSetting("home_dir")
end

function M.isInHome(path)
    return util.stringStartsWith(path, M.home():match("(.*)/?") .. "/")
end

return M
