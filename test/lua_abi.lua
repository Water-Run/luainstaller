--[[
Exact official-Lua ABI capability contract.

Author:
    WaterRun
File:
    lua_abi.lua
Date:
    2026-07-18
Updated:
    2026-07-18
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local lua_abi = require("luainstaller.lua_abi")

local function assert_equal(actual, expected, label)
    if actual ~= expected then
        error(string.format(
            "%s: expected %s, got %s",
            label,
            tostring(expected),
            tostring(actual)
        ), 2)
    end
end

local expected_builtins = {
    ["5.1"] = { utf8 = false, bit32 = false },
    ["5.2"] = { utf8 = false, bit32 = true },
    ["5.3"] = { utf8 = true, bit32 = true },
    ["5.4"] = { utf8 = true, bit32 = false },
    ["5.5"] = { utf8 = true, bit32 = false },
}

for abi, expected in pairs(expected_builtins) do
    assert_equal(lua_abi.normalize(abi), abi, "normalized ABI " .. abi)
    assert_equal(lua_abi.normalize("Lua " .. abi), abi, "normalized version " .. abi)
    assert_equal(lua_abi.isBuiltin(abi, "utf8"), expected.utf8, abi .. " utf8")
    assert_equal(lua_abi.isBuiltin(abi, "bit32"), expected.bit32, abi .. " bit32")
    assert_equal(lua_abi.isBuiltin(abi, "string"), true, abi .. " string")
    assert_equal(lua_abi.isBuiltin(abi, "not_a_builtin"), false, abi .. " external")
end

assert_equal(lua_abi.normalize("Lua 6.0"), nil, "unsupported future ABI")
assert_equal(lua_abi.normalize("LuaJIT 2.1.0"), nil, "LuaJIT version string")

local current, current_err = lua_abi.current()
assert(current, current_err)
assert_equal(current, tostring(_VERSION):match("Lua%s+(%d+%.%d+)"), "current ABI")
assert_equal(lua_abi.isOfficialCurrent(), true, "official current interpreter")
assert_equal(type(rawget(_G, "utf8")) == "table",
    expected_builtins[current].utf8, "current utf8 library")
assert_equal(type(rawget(_G, "bit32")) == "table",
    expected_builtins[current].bit32, "current bit32 library")

print("lua ABI capabilities ok")
