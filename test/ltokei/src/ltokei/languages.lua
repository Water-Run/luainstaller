--[[
Language detection and line classification rules for the ltokei sample.

Author:
    WaterRun
File:
    languages.lua
Date:
    2026-06-14
Updated:
    2026-06-14
]]
local M = {}

local by_extension = {
    c = "C",
    h = "C",
    lua = "Lua",
    md = "Markdown",
    markdown = "Markdown",
    py = "Python",
    js = "JavaScript",
}

function M.detect(path)
    local ext = tostring(path or ""):match("%.([A-Za-z0-9_]+)$")
    if not ext then
        return nil
    end
    return by_extension[ext:lower()]
end

local function trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function classify_slash(line, state)
    local text = trim(line)
    if text == "" then
        return "blank", state
    end
    if state.block then
        if text:find("%*/", 1, false) then
            state.block = false
        end
        return "comment", state
    end
    if text:sub(1, 2) == "//" then
        return "comment", state
    end
    if text:sub(1, 2) == "/*" then
        if not text:find("%*/", 3, false) then
            state.block = true
        end
        return "comment", state
    end
    return "code", state
end

local classifiers = {
    Lua = function(line, state)
        local text = trim(line)
        if text == "" then
            return "blank", state
        end
        if state.lua_block then
            local level = state.lua_block
            local close_pat = "]" .. string.rep("=", level) .. "]"
            if text:find(close_pat, 1, false) then
                state.lua_block = nil
            end
            return "comment", state
        end
        local eq_part = text:match("^%-%-%[(=*)%[")
        if eq_part then
            local level = #eq_part
            local close_pat = "]" .. string.rep("=", level) .. "]"
            if not text:find(close_pat, 1, false) then
                state.lua_block = level
            end
            return "comment", state
        end
        if text:sub(1, 2) == "--" then
            return "comment", state
        end
        return "code", state
    end,
    C = classify_slash,
    JavaScript = classify_slash,
    Python = function(line, state)
        local text = trim(line)
        if text == "" then
            return "blank", state
        end
        if text:sub(1, 1) == "#" then
            return "comment", state
        end
        return "code", state
    end,
    Markdown = function(line, state)
        local text = trim(line)
        if text == "" then
            return "blank", state
        end
        if state.block then
            if text:find("%-%->", 1, false) then
                state.block = false
            end
            return "comment", state
        end
        if text:sub(1, 4) == "<!--" then
            if not text:find("%-%->", 5, false) then
                state.block = true
            end
            return "comment", state
        end
        return "code", state
    end,
}

function M.classify(language, line, state)
    local classifier = classifiers[language]
    if not classifier then
        return "code", state or {}
    end
    return classifier(line, state or {})
end

return M
