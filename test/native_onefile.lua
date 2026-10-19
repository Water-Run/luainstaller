--[[
Native onefile and clean-target integration test.

Author:
    WaterRun
File:
    native_onefile.lua
Date:
    2026-07-14
Updated:
    2026-10-19
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
assert(built.onefile_mode == "extract" and built.selection_reason == "native-modules",
    "automatic mode did not choose extraction for a C module")
local rejected = require("luainstaller").bundle({
    entry = entry,
    out = path.join(root, "rejected" .. suffix),
    mode = "onefile",
    onefile_mode = "no-extract",
})
assert(not rejected.ok and rejected.error.type == "UnsupportedOnefileModeError")
assert(fs.pathType(path.join(root, "rejected" .. suffix)) == "missing")
assert(fs.pathType(built.executable) == "file")
assert(#(built.manifest.modules.native or {}) == 1,
    "native module was not recorded in the onefile manifest")
harness.assert_pe_closure(native_config, {
    native_config.runtime_path,
    native_module,
    built.executable,
})
assert(fs.removeFile(native_module))

local clean_path = path.join(root, "empty-path")
assert(fs.makeDirectory(clean_path))
local extract_root = path.join(root, "extraction")
assert(fs.makeDirectory(extract_root))
local argument = "onefile space & quote-\"value\""
local environment = {
    PATH = clean_path,
    LUA_PATH = "",
    LUA_CPATH = "",
    LD_LIBRARY_PATH = native_config.host.os == "android"
        and assert(os.getenv("PREFIX")) .. "/lib" or "",
    LUA_INIT = "",
    LUA_INIT_5_1 = "",
    LUA_INIT_5_2 = "",
    LUA_INIT_5_3 = "",
    LUA_INIT_5_4 = "",
    LUA_INIT_5_5 = "",
    TMPDIR = extract_root,
    TEMP = extract_root,
    TMP = extract_root,
}
local ran, output = process.outputCommand(built.executable, { argument }, environment)
assert(ran, output)
assert(output:find("native-probe-ok " .. argument, 1, true), output)

local hostile = path.join(root, "hostile-lua")
assert(fs.makeDirectory(hostile))
assert(fs.writeFile(path.join(hostile, "luai_native_probe.lua"),
    "return 'host-module-ran'\n"))
local hostile_environment = {}
for key, value in pairs(environment) do hostile_environment[key] = value end
hostile_environment.LUA_PATH = path.join(hostile, "?.lua")
for minor = 1, 5 do
    hostile_environment["LUA_PATH_5_" .. minor] = hostile_environment.LUA_PATH
    hostile_environment["LUA_CPATH_5_" .. minor] = ""
end
local priority_ok, priority_output = process.outputCommand(
    built.executable, { "native-priority" }, hostile_environment
)
assert(priority_ok and priority_output:find("native-probe-ok native-priority", 1, true),
    "host Lua source overrode a onefile C module: " .. tostring(priority_output))

local cache_root
for _, item in ipairs(assert(fs.listTree(extract_root))) do
    if item.type == "file" and item.path:match("/THIRD_PARTY_NOTICES%.md$") then
        cache_root = path.dirname(path.join(extract_root, item.path))
    end
end
assert(cache_root, "onefile payload cache was not created")
local cached_native = path.join(cache_root,
    ".luai/native/luai_native_probe." .. native_extension)
assert(fs.pathType(cached_native) == "file")
local blocker = path.join(cache_root, "THIRD_PARTY_NOTICES.md")
assert(fs.removeFile(blocker))
assert(fs.createDirectory(blocker))
local rejected, rejected_output = process.outputCommand(built.executable, {}, environment)
assert(not rejected, "onefile accepted a directory in place of a payload file")
assert(fs.pathType(cached_native) == "file",
    "failed extraction deleted a previously valid shared cache file: " .. tostring(rejected_output))
assert(fs.removeDirectory(blocker))
local repaired, repaired_output = process.outputCommand(built.executable, { argument }, environment)
assert(repaired and repaired_output:find("native-probe-ok " .. argument, 1, true), repaired_output)

assert(fs.removeTree(root))
print("native onefile clean-target ok: " .. _VERSION .. " native-probe-ok")
