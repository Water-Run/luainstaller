--[[
Lua-version compatibility contract tests for luainstaller.

Author:
    WaterRun
File:
    version_contract.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local compat = require("luainstaller.compat")
local info = compat.luaVersion()

assert(info.major == 5, "Lua 5.x is required")
assert(info.minor >= 1, "Lua 5.1 or newer is required")
assert(info.abi == string.format("lua%d.%d", info.major, info.minor))
assert(info.num == info.major * 100 + info.minor)

local interpreter = harness.lua_command()
assert(type(interpreter) == "string" and interpreter ~= "")
local output = harness.run_lua({ "-e", "io.write(_VERSION)" })
assert(output == _VERSION, string.format(
    "child interpreter mismatch: expected %s, got %s",
    _VERSION,
    tostring(output)
))

print("version contract ok: " .. info.version)
