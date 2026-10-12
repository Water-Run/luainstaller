--[[
Native onedir and clean-target integration tests.

Author:
    WaterRun
File:
    native_bundle.lua
Date:
    2026-07-14
Updated:
    2026-10-12
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local root = assert(fs.makePrivateDirectory("native-bundle"))
local out = path.join(root, "native-runtime")
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
local aliases_source = path.join(root, "native-aliases.c")
assert(fs.writeFile(aliases_source, [[
#include "lua_min.h"
#ifdef _WIN32
#define EXPORT __declspec(dllexport)
#else
#define EXPORT
#endif
EXPORT int luaopen_alias_root_leaf(lua_State *L) {
    lua_pushliteral(L, "c-root-ok"); return 1;
}
EXPORT int luaopen_alias_before(lua_State *L) {
    lua_pushliteral(L, "new-symbol"); return 1;
}
EXPORT int luaopen_alias_after(lua_State *L) {
    lua_pushliteral(L, "old-symbol"); return 1;
}
]]))
local alias_root = path.join(root, "alias_root." .. native_extension)
local aliases_ok, aliases_output = toolchain.compileNativeModule(
    native_config, aliases_source, alias_root, { work_dir = root }
)
assert(aliases_ok, aliases_output)
assert(fs.copyFile(alias_root, path.join(root, "alias_before-alias_after." .. native_extension)))
assert(fs.writeFile(entry, [[
assert(require("alias_root.leaf") == "c-root-ok")
assert(require("alias_before-alias_after")
    == (_VERSION == "Lua 5.1" and "old-symbol" or "new-symbol"))
local result = require("luai_native_probe")
print(result .. " " .. (arg[1] or "missing"))
]]))
local built = require("luainstaller").bundle({
    entry = entry,
    out = out,
    mode = "onedir",
})
assert(built.ok, built.error and built.error.message or "native onedir build failed")
assert(fs.pathType(built.executable) == "file")
assert(#(built.manifest.modules.native or {}) == 4,
    "native module was not recorded in the onedir manifest")
harness.assert_pe_closure(native_config, {
    native_config.runtime_path,
    native_module,
    built.executable,
    path.join(out, ".luai/native/luai_native_probe." .. native_extension),
    path.join(out, native_config.runtime_name or ""),
})

local clean_path = path.join(root, "empty-path")
assert(fs.makeDirectory(clean_path))
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
assert(output:find("native-probe-ok native-clean", 1, true), output)
assert(output:find("native-probe-ok", 1, true), output)

local rebuilt = require("luainstaller").bundle({
    entry = entry,
    out = out,
    mode = "onedir",
})
assert(rebuilt.ok, rebuilt.error and rebuilt.error.message or "native rebuild failed")
local rebuilt_ok, rebuilt_output = process.outputCommand(
    rebuilt.executable,
    { "native-rebuilt" },
    { PATH = clean_path, LUA_PATH = "", LUA_CPATH = "" }
)
assert(rebuilt_ok and rebuilt_output:find(
    "native-probe-ok native-rebuilt", 1, true
), rebuilt_output)

local failed_rebuild = path.join(root, "failed-rebuild.lua")
assert(fs.writeFile(failed_rebuild, string.format([[
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local result = require("luainstaller").bundle({
    entry = %q,
    out = %q,
    mode = "onedir",
})
assert(not result.ok and result.error.type == "ToolchainError")
io.write("failed rebuild rejected")
]], entry, out)))
local rejected, rejected_output = process.outputCommand(
    harness.lua_command(),
    { failed_rebuild },
    { LUAI_CC = path.join(root, "missing-compiler") }
)
assert(rejected and rejected_output == "failed rebuild rejected", rejected_output)
assert(fs.removeFile(native_module))
local preserved, preserved_output = process.outputCommand(
    rebuilt.executable,
    { "native-preserved" },
    { PATH = clean_path, LUA_PATH = "", LUA_CPATH = "" }
)
assert(preserved and preserved_output:find(
    "native-probe-ok native-preserved", 1, true
), preserved_output)

local runtime = built.manifest
    and built.manifest.launcher
    and built.manifest.launcher.lua_runtime
assert(type(runtime) == "table", "manifest omitted the selected Lua runtime")
assert(type(runtime.source_path) == "string" and runtime.source_path ~= "")
if runtime.destination_path then
    assert(fs.pathType(path.join(out, runtime.destination_path)) == "file")
end

local hostile = path.join(root, "hostile-lua")
assert(fs.makeDirectory(hostile))
assert(fs.writeFile(path.join(hostile, "luai_native_probe.lua"),
    "return 'host-module-ran'\n"))
local hostile_environment = {
    LUA_PATH = path.join(hostile, "?.lua"),
    LUA_CPATH = "",
}
for minor = 1, 5 do
    hostile_environment["LUA_PATH_5_" .. minor] = hostile_environment.LUA_PATH
    hostile_environment["LUA_CPATH_5_" .. minor] = ""
end
local priority_ok, priority_output = process.outputCommand(
    built.executable, { "native-priority" }, hostile_environment
)
assert(priority_ok and priority_output:find("native-probe-ok native-priority", 1, true),
    "host Lua source overrode a bundled C module: " .. tostring(priority_output))

local relocated = out
local names = { "relocated;directory" }
if package.config:sub(1, 1) == "/" then names[#names + 1] = "relocated?directory" end
for _, name in ipairs(names) do
    local destination = path.join(root, name)
    assert(fs.rename(relocated, destination))
    relocated = destination
    local executable = path.join(relocated, path.basename(built.executable))
    local moved_ok, moved_output = process.outputCommand(
        executable, { "native-relocated" }, { LUA_PATH = "", LUA_CPATH = "" }
    )
    assert(moved_ok and moved_output:find("native-probe-ok native-relocated", 1, true),
        "native module path was interpreted as a template: " .. tostring(moved_output))
end
assert(fs.removeFile(path.join(relocated, ".luai/native/luai_native_probe." .. native_extension)))
local missing_ok, missing_output = process.outputCommand(
    path.join(relocated, path.basename(built.executable)), {}, hostile_environment
)
assert(not missing_ok and not tostring(missing_output):find("host-module-ran", 1, true),
    "missing bundled C module fell back to host source: " .. tostring(missing_output))

assert(fs.removeTree(root))
print("native onedir clean-target ok: " .. _VERSION .. " native-probe-ok")
