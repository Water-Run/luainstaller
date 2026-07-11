--[[
Platform profile helpers for luainstaller.

Author:
    WaterRun
File:
    platform.lua
Date:
    2026-06-21
Updated:
    2026-07-11
]]

local process = require("luainstaller.process")

local M = {}

local PATH_SEP = package.config:sub(1, 1)

function M.normalizeArch(value)
    local arch = tostring(value or "unknown"):lower()
    if arch == "amd64" or arch == "x64" or arch == "x86_64" then
        return "x86_64"
    end
    if arch == "aarch64" or arch == "arm64" then
        return "arm64"
    end
    if arch == "x86" or arch:match("^i[3-6]86$") then
        return "x86"
    end
    return arch ~= "" and arch or "unknown"
end

function M.detectHost()
    if PATH_SEP == "\\" then
        return {
            os = "windows",
            arch = M.normalizeArch(
                os.getenv("PROCESSOR_ARCHITEW6432")
                    or os.getenv("PROCESSOR_ARCHITECTURE")
                    or "unknown"
            ),
        }
    end

    local uname_s = process.firstLine("uname -s")
    local uname_m = process.firstLine("uname -m")
    local os_name = "unknown"
    if uname_s == "Linux" then
        os_name = "linux"
    elseif uname_s == "Darwin" then
        os_name = "macos"
    end
    return {
        os = os_name,
        arch = M.normalizeArch(uname_m),
    }
end

function M.profile(opts)
    opts = opts or {}
    local host = opts.host or M.detectHost()
    local target_os = opts.target_os
    if target_os == nil or target_os == "" then
        target_os = host.os
    end
    local target_arch = M.normalizeArch(opts.target_arch
        or (target_os == "windows" and "x86_64")
        or host.arch)
    if target_os == "linux" then
        return {
            target_os = "linux",
            target_arch = target_arch,
            launcher_profile = "shared-lua",
            executable_suffix = "",
            native_extensions = { ".so" },
            loader_rpath = "$ORIGIN/.luai/native",
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    if target_os == "macos" then
        return {
            target_os = "macos",
            target_arch = target_arch,
            launcher_profile = "static-lua",
            executable_suffix = "",
            native_extensions = { ".so", ".dylib" },
            loader_rpath = "@loader_path/.luai/native",
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    if target_os == "windows" then
        return {
            target_os = "windows",
            target_arch = target_arch,
            launcher_profile = "windows-shared-lua",
            executable_suffix = ".exe",
            native_extensions = { ".dll" },
            loader_rpath = nil,
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    return {
        target_os = target_os,
        target_arch = target_arch,
        launcher_profile = "unknown",
        executable_suffix = "",
        native_extensions = { ".so" },
        loader_rpath = nil,
        lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
    }
end

return M
