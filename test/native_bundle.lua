--[[
Native onedir and clean-target integration tests.

Author:
    WaterRun
File:
    native_bundle.lua
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

local root = assert(fs.makePrivateDirectory("native-bundle"))
local out = path.join(root, "native-runtime")
local built = require("luainstaller").bundle({
    entry = "test/runtime_bundle/main.lua",
    out = out,
    mode = "onedir",
})
assert(built.ok, built.error and built.error.message or "native onedir build failed")
assert(fs.pathType(built.executable) == "file")

local clean_path = package.config:sub(1, 1) == "\\"
    and "C:\\Windows\\System32;C:\\Windows"
    or "/usr/bin:/bin"
local ran, output = process.outputCommand(built.executable, { "native-clean" }, {
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
assert(output:find("hello native-clean", 1, true), output)

local rebuilt = require("luainstaller").bundle({
    entry = "test/runtime_bundle/main.lua",
    out = out,
    mode = "onedir",
})
assert(rebuilt.ok, rebuilt.error and rebuilt.error.message or "native rebuild failed")
local rebuilt_ok, rebuilt_output = process.outputCommand(
    rebuilt.executable,
    { "native-rebuilt" },
    { PATH = clean_path, LUA_PATH = "", LUA_CPATH = "" }
)
assert(rebuilt_ok and rebuilt_output:find("hello native-rebuilt", 1, true), rebuilt_output)

local failed_rebuild = path.join(root, "failed-rebuild.lua")
assert(fs.writeFile(failed_rebuild, string.format([[
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local result = require("luainstaller").bundle({
    entry = "test/runtime_bundle/main.lua",
    out = %q,
    mode = "onedir",
})
assert(not result.ok and result.error.type == "ToolchainError")
io.write("failed rebuild rejected")
]], out)))
local rejected, rejected_output = process.outputCommand(
    harness.lua_command(),
    { failed_rebuild },
    { LUAI_CC = path.join(root, "missing-compiler") }
)
assert(rejected and rejected_output == "failed rebuild rejected", rejected_output)
local preserved, preserved_output = process.outputCommand(
    rebuilt.executable,
    { "native-preserved" },
    { PATH = clean_path, LUA_PATH = "", LUA_CPATH = "" }
)
assert(preserved and preserved_output:find("hello native-preserved", 1, true), preserved_output)

local runtime = built.manifest
    and built.manifest.launcher
    and built.manifest.launcher.lua_runtime
assert(type(runtime) == "table", "manifest omitted the selected Lua runtime")
assert(type(runtime.source_path) == "string" and runtime.source_path ~= "")
if runtime.destination_path then
    assert(fs.pathType(path.join(out, runtime.destination_path)) == "file")
end

assert(fs.removeTree(root))
print("native onedir clean-target ok: " .. _VERSION)
