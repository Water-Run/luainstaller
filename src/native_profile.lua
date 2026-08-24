--[[
Native Lua runtime-library policy for each supported launcher profile.

Author:
    WaterRun
File:
    native_profile.lua
Date:
    2026-07-18
Updated:
    2026-07-29
]]

local M = {}

local function libraryKind(candidate)
    local lower = tostring(candidate or ""):lower()
    if lower:match("%.dll%.a$") then return "import-windows" end
    if lower:match("%.so$") or lower:match("%.so%.%d[%d%.]*$") then
        return "shared-posix"
    end
    if lower:match("%.dylib$") then return "shared-macos" end
    if lower:match("%.dll$") then return "shared-windows" end
    if lower:match("%.lib$") then return "import-windows" end
    if lower:match("%.a$") then return "static" end
    return "unknown"
end

function M.libraryKind(candidate)
    return libraryKind(candidate)
end

function M.linkMode(candidate)
    local kind = libraryKind(candidate)
    if kind == "static" then return "static" end
    if kind == "shared-posix" or kind == "shared-macos"
        or kind == "shared-windows" or kind == "import-windows" then
        return "shared"
    end
    return nil
end

function M.acceptsLibrary(profile, candidate)
    profile = profile or {}
    local kind = libraryKind(candidate)
    local launcher_profile = profile.launcher_profile

    if profile.target_os == "windows" or launcher_profile == "windows-shared-lua" then
        local accepted = kind == "shared-windows" or kind == "import-windows"
        if accepted then return true end
        return false, "Windows requires a Lua DLL and .lib or .dll.a import library"
    end
    if profile.target_os == "macos" or launcher_profile == "static-lua" then
        local accepted = kind == "static" or kind == "shared-macos"
        if accepted then return true end
        return false, "macOS requires liblua.a or a Lua dylib"
    end
    if profile.target_os ~= "windows" or launcher_profile == "shared-lua" then
        local accepted = kind == "shared-posix" or kind == "static"
        if accepted then return true end
        return false, "POSIX requires a shared liblua or static liblua.a"
    end
    return false, "unsupported native Lua runtime profile"
end

function M.expectedLinkMode(profile, candidate)
    local selected = type(candidate) == "table"
        and (candidate.library_path or candidate.runtime_path)
        or candidate
    local mode = M.linkMode(selected)
    if mode then return mode end
    if profile and profile.target_os == "windows" then return "shared" end
    return nil
end

return M
