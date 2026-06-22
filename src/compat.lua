--[[
Compatibility diagnostics for luainstaller bundle planning.

Author:
    WaterRun
File:
    compat.lua
Date:
    2026-06-22
Updated:
    2026-06-22
]]

local platform = require("luainstaller.platform")

local M = {}

local function luaInfo()
    local version = _VERSION or "Lua"
    local major, minor = version:match("Lua%s+(%d+)%.(%d+)")
    return {
        version = version,
        abi = major and minor and ("lua" .. major .. "." .. minor) or "unknown",
    }
end

local function modeName(opts)
    return opts and opts.mode or "onedir"
end

local function launcherProfile(target_os)
    if target_os == "macos" then
        return "static-lua"
    end
    if target_os == "windows" then
        return "windows-shared-lua"
    end
    return "shared-lua"
end

local function countLibraries(dependencies)
    return #(dependencies and dependencies.libraries or {})
end

function M.diagnose(opts)
    opts = opts or {}
    local host = platform.detectHost()
    local profile = platform.profile({
        target_os = opts.target_os,
        lua_prefix = opts.lua_prefix,
    })
    local lua = luaInfo()
    local library_count = countLibraries(opts.dependencies)
    local notes = {
        "does not claim universal cross-platform output",
        "requires same OS, same architecture, same ABI, and same Lua ABI",
        "runtime require discovery only covers build-time executed code paths",
    }
    local warnings = {}

    if library_count > 0 then
        warnings[#warnings + 1] = "native Lua C modules may require external shared libraries that are not automatically closed over"
    end

    if profile.target_os ~= host.os then
        warnings[#warnings + 1] = "target profile differs from the build host; verify with the target runtime"
    end

    if profile.target_os == "windows" then
        notes[#notes + 1] = "Windows bundles require a compatible Lua DLL and compiler-runtime family"
    elseif profile.target_os == "macos" then
        notes[#notes + 1] = "macOS bundles require a matching static Lua prefix at build time"
    elseif profile.target_os == "linux" then
        notes[#notes + 1] = "Linux bundles use the copied shared Lua runtime and same-ABI native modules"
    end

    return {
        summary = "same OS, same architecture, same ABI, same Lua ABI",
        host = host,
        target = {
            os = profile.target_os,
            executable_suffix = profile.executable_suffix,
            launcher_profile = opts.launcher_profile or launcherProfile(profile.target_os),
        },
        lua = lua,
        mode = modeName(opts),
        native_library_count = library_count,
        notes = notes,
        warnings = warnings,
    }
end

return M
