--[[
Native onefile and clean-target integration test.

Author:
    WaterRun
File:
    native_onefile.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local root = assert(fs.makePrivateDirectory("native-onefile"))
local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""
local out = path.join(root, "native-onefile" .. suffix)
local built = require("luainstaller").bundle({
    entry = "test/runtime_bundle/main.lua",
    out = out,
    mode = "onefile",
})
local build_diagnostic = built.error and table.concat({
    tostring(built.error.message or "native onefile build failed"),
    tostring(built.error.command or ""),
    tostring(built.error.output or built.error.cause or ""),
}, "\n") or "native onefile build failed"
assert(built.ok, build_diagnostic)
assert(fs.pathType(built.executable) == "file")

local clean_path = package.config:sub(1, 1) == "\\"
    and "C:\\Windows\\System32;C:\\Windows"
    or "/usr/bin:/bin"
local argument = "onefile space & quote-\"value\""
local ran, output = process.outputCommand(built.executable, { argument }, {
    PATH = clean_path,
    LUA_PATH = "",
    LUA_CPATH = "",
    LUA_INIT = "",
    LUA_INIT_5_1 = "",
    LUA_INIT_5_2 = "",
    LUA_INIT_5_3 = "",
    LUA_INIT_5_4 = "",
    LUA_INIT_5_5 = "",
})
assert(ran, output)
assert(output:find("hello " .. argument, 1, true), output)

assert(fs.removeTree(root))
print("native onefile clean-target ok: " .. _VERSION)
