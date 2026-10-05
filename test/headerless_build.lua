--[[
Build and relink without installed Lua headers.

Author:
    WaterRun
File:
    headerless_build.lua
Date:
    2026-10-05
Updated:
    2026-10-05
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")
local luainstaller = require("luainstaller")
local config, config_err = toolchain.resolve()
assert(config, config_err and config_err.error.message)

local root = assert(fs.makePrivateDirectory("headerless-build"))
local prefix = path.join(root, "lua")
assert(fs.makeDirectory(prefix))
assert(fs.makeDirectory(path.join(prefix, "lib")))
assert(fs.makeDirectory(path.join(prefix, "bin")))
local source = config.runtime_path or config.static_library_path
local library_name = path.basename(config.library_path or source)
if config.host.os == "windows" then
    assert(fs.copyFile(config.runtime_path,
        path.join(prefix, "bin/" .. path.basename(config.runtime_path))))
    if config.library_path then
        assert(fs.copyFile(config.library_path, path.join(prefix, "lib/" .. library_name)))
    end
else
    assert(fs.copyFile(source, path.join(prefix, "lib/" .. library_name)))
    if config.runtime_name and config.runtime_name ~= library_name then
        assert(fs.copyFile(source, path.join(prefix, "lib/" .. config.runtime_name)))
    end
end

local headerless, headerless_err = toolchain.resolve({ lua_prefix = prefix })
assert(headerless, headerless_err and headerless_err.error.message)
assert(headerless.include_dir == nil, "headerless prefix selected an include directory")
assert(headerless.discovery_source == "explicit-prefix")

if config.host.os == "linux" and config.link_mode == "shared" then
    local soname_prefix = path.join(root, "soname-lua")
    assert(fs.makeDirectory(soname_prefix))
    assert(fs.makeDirectory(path.join(soname_prefix, "lib")))
    local soname = string.format("liblua%d.%d.so.0", config.lua_version.major, config.lua_version.minor)
    assert(fs.copyFile(source, path.join(soname_prefix, "lib/" .. soname)))
    if config.runtime_name ~= soname then
        assert(fs.copyFile(source, path.join(soname_prefix, "lib/" .. config.runtime_name)))
    end
    local resolved, resolve_err = toolchain.resolve({ lua_prefix = soname_prefix })
    assert(resolved, resolve_err and resolve_err.error.message)
    assert(resolved.library_path == path.join(soname_prefix, "lib/" .. soname))
end

local entry = path.join(root, "main.lua")
assert(fs.writeFile(entry, [[
assert(arg[1] == "space value" and arg[2] == "quote'\"value" and arg[3] == "")
print("headerless-ok " .. _VERSION)
]]))
local empty_path = path.join(root, "empty-path")
assert(fs.makeDirectory(empty_path))
for _, mode in ipairs({ "onedir", "onefile" }) do
    local built = luainstaller.bundle({
        entry = entry, out = path.join(root, mode), mode = mode, lua_prefix = prefix,
    })
    assert(built.ok, built.error and built.error.message)
    assert(#(built.warnings or {}) == 0, "pure Lua build emitted dependency warnings")
    local ran, output = process.outputCommand(built.executable,
        { "space value", "quote'\"value", "" }, {
            PATH = empty_path, LUA_PATH = "", LUA_CPATH = "", LUA_INIT = "",
        })
    assert(ran and output:find("headerless-ok " .. _VERSION, 1, true), output)
    if mode == "onedir" then
        local build_dir = path.join(built.out, ".luai/build")
        assert(fs.pathType(path.join(build_dir, "lua_min.h")) == "file",
            "bundle omitted the header needed for relinking")
        local compiled, compile_output = toolchain.compile(headerless,
            path.join(build_dir, "launcher.c"),
            path.join(built.out, "relinked" .. config.executable_suffix),
            { work_dir = root, rpath = config.profile.loader_rpath })
        assert(compiled, compile_output)
    end
end

-- Stale or unrelated system headers do not participate in generated builds.
assert(fs.makeDirectory(path.join(prefix, "include")))
for _, name in ipairs({ "lua.h", "lauxlib.h", "lualib.h" }) do
    assert(fs.writeFile(path.join(prefix, "include/" .. name),
        "#error system Lua headers must not be used\n"))
end
local mismatched = luainstaller.bundle({
    entry = entry, out = path.join(root, "stale-headers"), lua_prefix = prefix,
})
assert(mismatched.ok, mismatched.error and mismatched.error.message)
local code, output, diagnostic = harness.invoke_cli("luai", {
    "-b", entry, "-o", path.join(root, "verbose"), "--lua-prefix", prefix, "--verbose",
})
assert(code == 0, diagnostic)
harness.assert_contains(output, "explicit-prefix")
harness.assert_contains(output, "lua_min.h")

assert(fs.removeTree(root))
print("headerless build and relink ok: " .. _VERSION)
