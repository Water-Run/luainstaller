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
    2026-07-11
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
    if IS_WINDOWS then
        path = path:lower()
        root = root:lower()
    end
    if path == root then
        return true
    end
    if root == "." then
        return not M.isAbsolute(path)
            and path ~= ".."
            and path:sub(1, 3) ~= "../"
    end
    local prefix = root:sub(-1) == "/" and root or (root .. "/")
    return path:sub(1, #prefix) == prefix
end

--@description: True when path is a relative path with no empty, ".", or ".." segments.
function M.isSafeRelative(value)
    local path = tostring(value or ""):gsub("\\", "/")
    if path == "" or path:find("\0", 1, true) or path:sub(1, 1) == "/"
        or path:match("^%a:") or path:sub(-1) == "/" then
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

local WINDOWS_RESERVED_STEMS = {
    CON = true,
    PRN = true,
    AUX = true,
    NUL = true,
    ["CONIN$"] = true,
    ["CONOUT$"] = true,
    ["CLOCK$"] = true,
}

local function containsControlByte(value)
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 32 or byte == 127 then return true end
    end
    return false
end

local function containsNonAsciiByte(value)
    for index = 1, #value do
        if value:byte(index) >= 128 then return true end
    end
    return false
end

--@description: Validate a slash-based relative path for the destination OS.
--@return: boolean, string|nil - Success and normalized value, or false and reason.
function M.validateTargetRelative(value, target_os)
    if type(value) ~= "string" then
        return false, "target path must be a string"
    end
    local portable = value:gsub("\\", "/")
    if containsControlByte(portable) then
        return false, "target path contains a control byte"
    end
    if not M.isSafeRelative(portable) then
        return false, "target path must be a safe relative path"
    end
    target_os = target_os or (IS_WINDOWS and "windows" or "linux")
    if target_os ~= "linux" and target_os ~= "macos" and target_os ~= "windows"
        and target_os ~= "unknown" then
        return false, "unknown target OS"
    end
    if (target_os == "windows" or target_os == "macos")
        and containsNonAsciiByte(portable) then
        return false, "target path contains non-ASCII bytes that cannot be case-folded safely"
    end

    for segment in portable:gmatch("[^/]+") do
        if #segment > 255 then
            return false, "target path component exceeds 255 bytes"
        end
        if target_os == "windows" then
            if segment:find("[<>:\"|?*]") then
                return false, "Windows target path contains an invalid character"
            end
            if segment:match("[%. ]$") then
                return false, "Windows target path component ends in a space or dot"
            end
            local stem = (segment:match("^([^%.]+)") or segment)
                :gsub("[ .]+$", "")
                :upper()
            if WINDOWS_RESERVED_STEMS[stem]
                or stem:match("^COM[1-9]$")
                or stem:match("^LPT[1-9]$")
                or stem == "COM¹" or stem == "COM²" or stem == "COM³"
                or stem == "LPT¹" or stem == "LPT²" or stem == "LPT³" then
                return false, "Windows target path uses a reserved device name"
            end
        end
    end
    return true, M.normalize(portable)
end

--@description: Canonical collision key for a destination path on the target OS.
function M.targetKey(value, target_os)
    local key = M.normalize(tostring(value or ""):gsub("\\", "/"))
    if target_os == "windows" or target_os == "macos" then
        return key:lower()
    end
    return key
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
    return M.join(M.currentDirectory(), normalized)
end

function M.dirname(value)
    local normalized = M.normalize(value)
    if normalized == "/" or normalized == "//" or normalized:match("^%a:/$") then
        return normalized
    end
    local slash = normalized:match("^.*()/")
    if not slash then
        return "."
    end
    if slash == 1 then
        return "/"
    end
    if slash == 2 and normalized:sub(1, 2) == "//" then
        return "//"
    end
    if slash == 3 and normalized:match("^%a:/") then
        return normalized:sub(1, 3)
    end
    return normalized:sub(1, slash - 1)
end

function M.join(left, right)
    left = M.normalize(left)
    right = tostring(right or "")
    if M.isAbsolute(right) then
        return M.normalize(right)
    end
    if left == "." then
        return M.normalize(right)
    end
    if left == "/" or left == "//" or left:match("^%a:/$") then
        return M.normalize(left .. right)
    end
    return M.normalize(left .. "/" .. right)
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
        if source:match("/init%.lua$") then
            local package_name = M.basename(M.dirname(source))
            if package_name ~= "" and package_name ~= "." and package_name ~= "/" then
                relative = package_name .. "/init.lua"
            end
        end
        relative = relative or M.basename(source)
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
