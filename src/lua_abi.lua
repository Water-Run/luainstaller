--[[
Runtime identity and Lua ABI capabilities shared by analysis and bundling.

Author:
    WaterRun
File:
    lua_abi.lua
Date:
    2026-07-18
Updated:
    2026-10-15
]]

local M = {}

local COMMON_BUILTINS = {
    ["_G"] = true,
    ["coroutine"] = true,
    ["debug"] = true,
    ["io"] = true,
    ["math"] = true,
    ["os"] = true,
    ["package"] = true,
    ["string"] = true,
    ["table"] = true,
}

local ABI_BUILTINS = {
    ["5.1"] = {},
    ["5.2"] = { bit32 = true },
    ["5.3"] = { bit32 = true, utf8 = true },
    ["5.4"] = { utf8 = true },
    ["5.5"] = { utf8 = true },
}

function M.normalize(value)
    local text = tostring(value or "")
    local major, minor = text:match("Lua%s+(%d+)%.(%d+)")
    if not major then
        major, minor = text:match("^(%d+)%.(%d+)$")
    end
    local abi = major and minor and (major .. "." .. minor) or nil
    return ABI_BUILTINS[abi] and abi or nil
end

local LUAJIT_BUILTINS = {
    bit = true, jit = true, ffi = true,
    ["jit.util"] = true, ["jit.opt"] = true, ["jit.profile"] = true,
    ["string.buffer"] = true,
}
local OPTIONAL_BUILTINS = {
    ["string.buffer"] = "string_buffer",
    ["jit.profile"] = "jit_profile",
}

function M.builtinNames(identity)
    identity = identity or M.info()
    local names = {}
    for name in pairs(COMMON_BUILTINS) do names[#names + 1] = name end
    for name in pairs(ABI_BUILTINS[M.normalize(identity.version)] or {}) do names[#names + 1] = name end
    if identity.kind == "luajit" then
        for name in pairs(LUAJIT_BUILTINS) do
            if not OPTIONAL_BUILTINS[name] or identity[OPTIONAL_BUILTINS[name]] then
                names[#names + 1] = name
            end
        end
    end
    table.sort(names)
    return names
end

-- The same source runs in discovery, native probes and generated launchers.
-- _VERSION alone cannot distinguish official Lua 5.1 from LuaJIT.
local IDENTITY_SOURCE = [[
local version = tostring(_VERSION)
local major, minor = version:match("^Lua (%d+)%.(%d+)$")
major, minor = tonumber(major), tonumber(minor)
local j = rawget(_G, "jit")
local is_jit = type(j) == "table" and type(j.version) == "string"
    and type(j.status) == "function"
local info = {
    kind = is_jit and "luajit" or "lua", version = version,
    major = major, minor = minor,
    num = major and minor and major * 100 + minor or nil,
    abi = major and minor and ("lua" .. major .. "." .. minor) or "unknown",
    official = not is_jit,
    supported = major == 5 and minor ~= nil and minor >= 1 and minor <= 5,
}
if is_jit then
    info.runtime_version = j.version
    info.runtime_version_num = j.version_num
    info.os, info.arch = j.os, j.arch
    info.lua52compat = #setmetatable({}, {__len=function() return 1 end}) == 1
    local ok, ffi = pcall(require, "ffi")
    info.ffi = ok and type(ffi) == "table" and type(ffi.abi) == "function"
    info.gc64 = info.ffi and ffi.abi("gc64") or false
    local util_ok, util = pcall(require, "jit.util")
    info.jit_compiler = util_ok and type(util) == "table" and type(util.traceinfo) == "function"
    info.string_buffer = type(package.preload["string.buffer"]) == "function"
        or type(package.loaded["string.buffer"]) == "table"
    info.jit_profile = type(package.preload["jit.profile"]) == "function"
        or type(package.loaded["jit.profile"]) == "table"
    info.supported = major == 5 and minor == 1
        and j.version:match("^LuaJIT 2%.1[%.%- ]") ~= nil
        and type(j.version_num) == "number" and j.version_num >= 20100
        and j.version_num < 20200 and info.ffi
end
return info
]]

local readIdentity = assert((loadstring or load)(IDENTITY_SOURCE, "@luainstaller-runtime-identity"))

function M.info()
    return readIdentity()
end

function M.validateInfo(current)
    current = current or M.info()
    local major, minor = tonumber(current.major), tonumber(current.minor)
    if not major or not minor then
        major, minor = tostring(current.version):match("^Lua (%d+)%.(%d+)$")
        major, minor = tonumber(major), tonumber(minor)
    end
    local kind = current.kind or (current.official == false and "unknown" or "lua")
    if major ~= 5 or not minor or minor < 1 or minor > 5
        or (kind ~= "lua" and kind ~= "luajit")
        or current.supported == false then
        return nil, "An official Lua 5.1 through 5.5 or LuaJIT 2.1 runtime is required"
    end
    if kind == "luajit" and (minor ~= 1 or current.ffi ~= true
        or type(current.runtime_version) ~= "string"
        or not current.runtime_version:match("^LuaJIT 2%.1[%.%- ]")
        or type(current.runtime_version_num) ~= "number"
        or current.runtime_version_num < 20100 or current.runtime_version_num >= 20200
        or type(current.arch) ~= "string" or type(current.os) ~= "string"
        or type(current.gc64) ~= "boolean" or type(current.lua52compat) ~= "boolean"
        or type(current.jit_compiler) ~= "boolean"
        or type(current.string_buffer) ~= "boolean" or type(current.jit_profile) ~= "boolean") then
        return nil, "LuaJIT 2.1 with FFI and a complete runtime identity is required"
    end
    local info = {
        kind = kind, official = kind == "lua", supported = true,
        version = string.format("Lua %d.%d", major, minor),
        major = major, minor = minor, num = major * 100 + minor,
        abi = string.format("lua%d.%d", major, minor),
    }
    if kind == "luajit" then
        for _, key in ipairs({"runtime_version", "runtime_version_num", "os", "arch",
            "gc64", "lua52compat", "ffi", "jit_compiler", "string_buffer", "jit_profile"}) do
            info[key] = current[key]
        end
    end
    return info
end

function M.checkSource(current)
    local info, err = M.validateInfo(current)
    if not info then error({type="UnsupportedLuaVersionError", message=err}) end
    local source = { "local r = (function()\n" .. IDENTITY_SOURCE .. "end)()" }
    local keys = {"kind", "version"}
    if info.kind == "luajit" then
        for _, key in ipairs({"runtime_version", "runtime_version_num", "os", "arch",
            "gc64", "lua52compat", "ffi", "jit_compiler", "string_buffer", "jit_profile"}) do keys[#keys + 1] = key end
    end
    for _, key in ipairs(keys) do
        local value = info[key]
        local literal = type(value) == "string" and string.format("%q", value) or tostring(value)
        source[#source + 1] = "assert(r." .. key .. " == " .. literal .. ", "
            .. string.format("%q", "runtime identity mismatch: " .. key .. " (expected " .. tostring(value) .. ")") .. ")"
    end
    source[#source + 1] = "return true"
    return table.concat(source, "\n")
end

function M.current()
    local info, err = M.validateInfo()
    return info and M.normalize(info.version) or nil, err
end

function M.checkCString(current)
    local source = M.checkSource(current)
    return '"' .. source:gsub("\\", "\\\\"):gsub('"', '\\"')
        :gsub("\r", "\\r"):gsub("\n", '\\n"\n"') .. '"'
end

function M.isOfficialCurrent()
    local info = M.validateInfo()
    return info ~= nil and info.kind == "lua"
end

function M.isBuiltin(abi, module_name)
    if type(abi) == "table" then
        if abi.kind == "luajit" and LUAJIT_BUILTINS[module_name] then
            local capability = OPTIONAL_BUILTINS[module_name]
            return not capability or abi[capability] == true
        end
        abi = abi.version
    end
    local normalized = M.normalize(abi)
    local extras = normalized and ABI_BUILTINS[normalized] or nil
    return extras ~= nil
        and (COMMON_BUILTINS[module_name] == true or extras[module_name] == true)
end

return M
