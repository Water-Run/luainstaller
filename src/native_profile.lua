--[[
Native Lua runtime-library policy for each supported launcher profile.

Author:
    WaterRun
File:
    native_profile.lua
Date:
    2026-07-18
Updated:
    2026-07-18
]]

local M = {}

local function libraryKind(candidate)
    local lower = tostring(candidate or ""):lower()
    if lower:match("%.so$") or lower:match("%.so%.%d[%d%.]*$") then
        return "shared-posix"
    end
    if lower:match("%.dylib$") then return "shared-macos" end
    if lower:match("%.dll$") then return "shared-windows" end
    if lower:match("%.lib$") then return "import-windows" end
    if lower:match("%.a$") then return "static" end
    return "unknown"
end

function M.acceptsLibrary(profile, candidate)
    profile = profile or {}
    local kind = libraryKind(candidate)
    local launcher_profile = profile.launcher_profile

    if profile.target_os == "windows" or launcher_profile == "windows-shared-lua" then
        local accepted = kind == "shared-windows" or kind == "import-windows"
        return accepted, accepted and nil
            or "Windows requires a Lua DLL and MSVC import library"
    end
    if profile.target_os == "macos" or launcher_profile == "static-lua" then
        local accepted = kind == "static"
        return accepted, accepted and nil or "macOS requires static liblua.a"
    end
    if profile.target_os == "linux" or launcher_profile == "shared-lua" then
        local accepted = kind == "shared-posix"
        return accepted, accepted and nil or "Linux/POSIX requires a shared liblua"
    end
    return false, "unsupported native Lua runtime profile"
end

function M.expectedLinkMode(profile)
    if profile and (profile.target_os == "macos"
        or profile.launcher_profile == "static-lua") then
        return "static"
    end
    return "shared"
end

return M
