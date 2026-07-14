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

assert(compat.band(0xf0, 0x3c) == 0x30)
assert(compat.bor(0xf0, 0x0f) == 0xff)
assert(compat.bxor(0xaa, 0xff) == 0x55)
assert(compat.bnot(0) == 0xffffffff)
assert(compat.lshift(0x12, 8) == 0x1200)
assert(compat.rshift(0x12345678, 8) == 0x00123456)
assert(compat.rrotate(0x12345678, 8) == 0x78123456)
assert(compat.packU32BE(0x12345678) == "\18\52\86\120")

local loaded = assert(compat.loadText("return value", "@compat", { value = 42 }))
assert(loaded() == 42)
local bytecode = string.dump(function() return true end)
local rejected, reject_error = compat.loadText(bytecode, "@bytecode", {})
assert(rejected == nil)
assert(type(reject_error) == "string" and reject_error ~= "")

local hash = require("luainstaller.hash")
assert(hash.sha256("abc") ==
    "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
if info.minor >= 3 then
    assert(hash.backend() == "native-operators")
    local started = os.clock()
    hash.sha256(string.rep("a", 1024 * 1024))
    local elapsed = os.clock() - started
    assert(elapsed < 3, string.format("native SHA-256 backend is too slow: %.2fs", elapsed))
end

print("version contract ok: " .. info.version)
