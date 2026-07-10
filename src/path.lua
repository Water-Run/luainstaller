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
    2026-07-10
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

--@description: True when path is root or a descendant of root after normalization.
function M.isWithin(path, root)
    path = M.normalize(path)
    root = M.normalize(root)
    if path == root then
        return true
    end
    local prefix = root == "/" and "/" or (root .. "/")
    return path:sub(1, #prefix) == prefix
end

--@description: True when path is a relative path with no empty, ".", or ".." segments.
function M.isSafeRelative(value)
    local path = tostring(value or ""):gsub("\\", "/")
    if path == "" or path:sub(1, 1) == "/" or path:match("^%a:/") then
        return false
    end
    if path:match("^//") then
        return false
    end
    for segment in path:gmatch("[^/]+") do
        if segment == "" or segment == "." or segment == ".." then
            return false
        end
    end
    if path:find("//", 1, true) then
        return false
    end
    return true
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

--@description: Dotted module name from a Lua file path relative to entry's directory.
function M.moduleNameFromLuaPath(lua_path, entry)
    local source = M.normalize(M.absolute(lua_path))
    local entry_dir = M.dirname(M.absolute(entry or source))
    local prefix = entry_dir == "/" and "/" or (entry_dir .. "/")
    local relative
    if source:sub(1, #prefix) == prefix then
        relative = source:sub(#prefix + 1)
    else
        relative = M.basename(source)
    end
    relative = M.normalize(relative)
    if relative:match("/init%.lua$") then
        relative = relative:gsub("/init%.lua$", "")
    else
        relative = relative:gsub("%.lua$", "")
    end
    local fallback = M.basename(source):gsub("%.lua$", "")
    if relative == "" or relative == "." or M.isAbsolute(relative) then
        return fallback
    end
    for segment in relative:gmatch("[^/]+") do
        if segment == "." or segment == ".." then
            return fallback
        end
    end
    return (relative:gsub("/", "."))
end

return M
