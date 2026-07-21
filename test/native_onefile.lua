--[[
Native onefile and clean-target integration test.

Author:
    WaterRun
File:
    native_onefile.lua
Date:
    2026-07-14
Updated:
    2026-07-18
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local root = assert(fs.makePrivateDirectory("native-onefile"))
local suffix = package.config:sub(1, 1) == "\\" and ".exe" or ""
local out = path.join(root, "native-onefile" .. suffix)
local entry = path.join(root, "main.lua")
local toolchain = require("luainstaller.toolchain")
local native_config, native_config_err = toolchain.resolve()
assert(native_config, native_config_err and native_config_err.error.message)
assert(native_config.native_module_verified == true)
local native_extension = toolchain.nativeModuleExtension(native_config)
local native_module = path.join(root, "luai_native_probe." .. native_extension)
local native_ok, native_output, native_command = toolchain.compileNativeModule(
    native_config,
    "test/fixtures/native_probe.c",
    native_module,
    { work_dir = root }
)
assert(native_ok, table.concat({
    tostring(native_command or "native module compile failed"),
    tostring(native_output or ""),
}, "\n"))
if native_config.host.os == "linux" then
    assert(not tostring(native_command):find("-llua", 1, true),
        "ordinary Linux C module was linked to liblua")
    assert(not tostring(native_command):find(
        tostring(native_config.library_path), 1, true
    ), "ordinary Linux C module used the selected liblua path")
end
assert(fs.writeFile(entry, [[
local result = require("luai_native_probe")
print(result .. " " .. (arg[1] or "missing"))
]]))
local built = require("luainstaller").bundle({
    entry = entry,
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
assert(#(built.manifest.modules.native or {}) == 1,
    "native module was not recorded in the onefile manifest")
harness.assert_pe_closure(native_config, {
    native_config.runtime_path,
    native_module,
    built.executable,
})
assert(fs.removeFile(native_module))

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
assert(output:find("native-probe-ok " .. argument, 1, true), output)

assert(fs.removeTree(root))
print("native onefile clean-target ok: " .. _VERSION .. " native-probe-ok")
