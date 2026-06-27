--[[
Platform profile helpers for luainstaller.

Author:
    WaterRun
File:
    platform.lua
Date:
    2026-06-21
Updated:
    2026-06-21
]]

local process = require("luainstaller.process")

local M = {}

local PATH_SEP = package.config:sub(1, 1)

function M.detectHost()
    if PATH_SEP == "\\" then
        return {
            os = "windows",
            arch = os.getenv("PROCESSOR_ARCHITECTURE") or "unknown",
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
        arch = uname_m or "unknown",
    }
end

function M.profile(opts)
    opts = opts or {}
    local host = M.detectHost()
    local target_os = opts.target_os or host.os
    if target_os == "linux" then
        return {
            target_os = "linux",
            executable_suffix = "",
            native_extensions = { ".so" },
            loader_rpath = "$ORIGIN/.luai/native",
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    if target_os == "macos" then
        return {
            target_os = "macos",
            executable_suffix = "",
            native_extensions = { ".so", ".dylib" },
            loader_rpath = "@loader_path/.luai/native",
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    if target_os == "windows" then
        return {
            target_os = "windows",
            executable_suffix = ".exe",
            native_extensions = { ".dll" },
            loader_rpath = nil,
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    return {
        target_os = target_os,
        executable_suffix = "",
        native_extensions = { ".so" },
        loader_rpath = nil,
        lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
    }
end

return M
