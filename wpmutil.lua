local util = require("util")

local M = {}
M.log = { prefix = "WPM Stats - " }
M.math = {}

local logger = require("logger")

function M.log.warn(...)
    logger.warn(M.log.prefix, ...)
end
function M.log.dbg(...)
    logger.dbg(M.log.prefix, ...)
end

function M.math.round(x, decimals)
    local factor = 10 ^ (decimals or 0)
    return math.floor(x * factor + 0.5) / factor
end

function M.math.secondsToMinutes(seconds, precision)
    return M.math.round(seconds / 60, precision)
end

function M.insertFallbackValues(values, fallbacks)
    for key, value in pairs(fallbacks) do
        if values[key] == nil then
            values[key] = value
        elseif type(value) == "table" and type(values[key]) == "table" then
            M.applyDefaults(values[key], value)
        end
    end
    return values
end

function M.readerSetting(setting, default)
    return G_reader_settings:readSetting(setting, default)
end

function M.readerSettingSafe(setting)
    return G_reader_settings:has(setting) and M.readerSetting(setting) or {}
end

function M.math.floatEqual(a, b, epsilon)
    epsilon = epsilon or 1e-6
    return a == b or math.abs(a - b) < epsilon
end

function M.homeDir()
    return M.readerSetting("home_dir")
end

function M.isInHome(path)
    return util.stringStartsWith(path, M.homeDir():match("(.*)/?") .. "/")
end

return M
