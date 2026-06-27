--[[
Shared path helpers for luainstaller.
Provides normalized, slash-based path operations used by analysis,
manifest construction, and bundle assembly.

Author:
    WaterRun
File:
    path.lua
Date:
    2026-06-27
Updated:
    2026-06-27
]]

local process = require("luainstaller.process")

local M = {}

local PATH_SEP = package.config:sub(1, 1)
local IS_WINDOWS = PATH_SEP == "\\"

function M.normalize(value)
    local path = tostring(value or ""):gsub("\\", "/")
    local prefix = ""
    if path:match("^//") then
        prefix = "//"
        path = path:sub(3)
    elseif path:match("^%a:/") then
        prefix = path:sub(1, 3)
        path = path:sub(4)
    elseif path:sub(1, 1) == "/" then
        prefix = "/"
        path = path:sub(2)
    end

    local parts = {}
    for segment in path:gmatch("[^/]+") do
        if segment == ".." then
            if #parts > 0 and parts[#parts] ~= ".." then
                parts[#parts] = nil
            elseif prefix == "" then
                parts[#parts + 1] = ".."
            end
        elseif segment ~= "." and segment ~= "" then
            parts[#parts + 1] = segment
        end
    end

    local result = prefix .. table.concat(parts, "/")
    if result == "" then
        return "."
    end
    return result
end

function M.isAbsolute(value)
    local path = tostring(value or "")
    return path:sub(1, 1) == "/" or path:match("^%a:[/\\]") ~= nil
end

function M.currentDirectory()
    local line = process.firstLine(IS_WINDOWS and "cd" or "pwd")
    if line then
        return M.normalize(line)
    end
    return "."
end

function M.absolute(value)
    local normalized = M.normalize(value)
    if M.isAbsolute(normalized) then
        return normalized
    end
    return M.normalize(M.currentDirectory() .. "/" .. normalized)
end

function M.dirname(value)
    local normalized = M.normalize(value)
    return normalized:match("^(.+)/[^/]+$") or "."
end

function M.basename(value)
    local normalized = M.normalize(value)
    return normalized:match("[^/]+$") or normalized
end

function M.stem(value)
    local name = M.basename(value)
    return name:match("^(.+)%.[^%.]+$") or name
end

function M.extension(value)
    local name = M.basename(value)
    return name:match("(%.[^%.]+)$")
end

return M
