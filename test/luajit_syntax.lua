--[[
LuaJIT literal and declaration boundaries in static dependency discovery.

Author:
    WaterRun
File:
    luajit_syntax.lua
Date:
    2026-10-15
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
assert(type(jit) == "table", "run this suite with LuaJIT")
local analyzer = require("luainstaller.analyzer")
local compat = require("luainstaller.compat")

local function requires(source)
    analyzer.validateSource(source, "jit-syntax.lua")
    return analyzer.LuaLexer.new(source, "jit-syntax.lua"):extractRequires()
end

for _, number in ipairs({"1LL", "1ULL", "1i", "0x1p-2"}) do
    local found = requires("local require = " .. number .. " and require('literal-dependency')")
    assert(#found == 1 and found[1].name == "literal-dependency", number .. " ended the initializer early")
end
local unicode = requires("local caférequire = function() end; caférequire('not-a-module'); require('real')")
assert(#unicode == 1 and unicode[1].name == "real", "UTF-8 identifier split into require")

if compat.loadText("const value = 1") then
    local found = requires("do const require = function() end; require('shadowed') end; require('real')")
    assert(#found == 1 and found[1].name == "real", "const binding escaped its scope")
    for _, number in ipairs({"1_000", "0b1010", "0x1_00ULL"}) do
        local found = requires("local require = " .. number .. " and require('numeric-dependency')")
        assert(#found == 1 and found[1].name == "numeric-dependency", number .. " split into identifiers")
    end
    for _, source in ipairs({
        "local f = require -> require('shadowed')",
        "local value = true ? false ? require('first') : 2 : require('second')",
        "local value = {}; local f = value?.require",
    }) do
        local ok, err = pcall(requires, source)
        assert(not ok and type(err) == "table" and err.type == "DiscoveryError",
            "unsupported static syntax needs an explicit diagnostic, not a partial dependency list")
    end
    for _, source in ipairs({
        "local value = true ? require('first') :require('second')",
        "local value = true ? require('first', 42) : require('second')",
        "local require = true ? pcall(require, 'first', 42) : require('second')",
        "local require = true ? require('first') : require('second')",
        "local value = true ? (false ? require('first') : require('second')) : 0",
        "local value = true ? (object:require('ignored')) : require('first'); require('second')",
        "local n = 0; n += require('first'); require('second')",
    }) do
        local found = requires(source)
        assert(#found == 2 and found[1].name == "first" and found[2].name == "second",
            "LuaJIT expression lost a dependency: " .. source)
    end
end
print("LuaJIT syntax boundaries ok")
