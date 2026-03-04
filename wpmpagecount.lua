local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local ReaderUI = require("apps/reader/readerui")

local filemanagerutil = require("apps/filemanager/filemanagerutil")
local logger = require("logger")
local logprefix = "WPM Stats - "

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

                        local function checkLine(l)
                            if not do_break_p then
                                found_pages, found_pagev, do_break_p = parse_opf_file("pages", found_pages, found_pagev, l)
                            end
                            if not do_break_w then
                                found_words, found_wordv, do_break_w = parse_opf_file("words", found_words, found_wordv, l)
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
                        local p = nil
                        local w = nil
                        if found_pagev and found_pagev ~= "0" then
                            logger.dbg(logprefix, "Pagecount found in opf metadata ", fname, found_pagev)
                            p = tonumber(found_pagev)
                        end
                        if found_wordv and found_wordv ~= "0" then
                            logger.dbg(logprefix, "Wordcount found in opf metadata ", fname, found_wordv)
                            w = tonumber(found_wordv)
                        end
                        if p or w then
                            return p, w
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

return getPageCount
