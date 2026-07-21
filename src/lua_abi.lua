--[[
Official Lua ABI capability helpers shared by analysis and discovery.

Author:
    WaterRun
File:
    lua_abi.lua
Date:
    2026-07-18
Updated:
    2026-07-18
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

function M.current()
    local abi = M.normalize(_VERSION)
    local jit_value = rawget(_G, "jit")
    local is_luajit = type(jit_value) == "table"
        and type(jit_value.version) == "string"
        and type(jit_value.status) == "function"
    if not abi or is_luajit then
        return nil, "expected official Lua 5.1 through 5.5"
    end
    return abi
end

function M.isOfficialCurrent()
    return M.current() ~= nil
end

function M.isBuiltin(abi, module_name)
    local normalized = M.normalize(abi)
    local extras = normalized and ABI_BUILTINS[normalized] or nil
    return extras ~= nil
        and (COMMON_BUILTINS[module_name] == true or extras[module_name] == true)
end

return M
