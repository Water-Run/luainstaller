--[[
Real LuaJIT libraries cannot masquerade as official Lua or another build.

Author:
    WaterRun
File:
    luajit_mismatch.lua
Date:
    2026-10-15
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
assert(type(jit) == "table", "run this suite with LuaJIT")
local api = require("luainstaller")
local lua_abi = require("luainstaller.lua_abi")
local toolchain = require("luainstaller.toolchain")
local launcher = require("luainstaller.launcher")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("luajit-mismatch"))
local info = lua_abi.info()
local original_info = lua_abi.info
local success, failure = pcall(function()
    local static, err = toolchain.resolve({require_static=true})
    assert(static, err and err.error.message)
    local disguised = path.join(root, "official-prefix")
    assert(fs.makeDirectory(path.join(disguised, "lib")))
    local archive = static.host.os == "windows" and "lua51-static.lib" or "liblua.a"
    assert(fs.copyFile(static.static_library_path, path.join(disguised, "lib/" .. archive)))
    local official = {kind="lua", version="Lua 5.1", major=5, minor=1, num=501, abi="lua5.1", supported=true}
    local wrong, wrong_error = toolchain.resolve({require_static=true, lua_prefix=disguised, lua_version=official})
    assert(not wrong and wrong_error.error.type == "ToolchainError")
    assert(#(wrong_error.error.failures or {}) > 0, "the real library must reach the capability probe")

    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, "print('mismatched-runtime-executed')\n"))
    lua_abi.info = function() return official end
    local discovery = api.analyze({entry=entry, discovery_mode="runtime", lua=harness.lua_command()})
    lua_abi.info = original_info
    assert(not discovery.ok and discovery.error.type == "ToolchainError", "LuaJIT passed as an official 5.1 discovery interpreter")

    for _, field in ipairs({"runtime_version", "gc64", "lua52compat", "jit_compiler", "string_buffer", "jit_profile"}) do
        local altered = {}
        for key, value in pairs(info) do altered[key] = value end
        altered[field] = field == "runtime_version" and "LuaJIT 2.1.mismatched" or not info[field]
        local accepted, rejected = toolchain.resolve({require_static=true, lua_version=altered})
        assert(not accepted and rejected.error.type == "ToolchainError", "accepted a different LuaJIT " .. field)
        assert(#(rejected.error.failures or {}) > 0)
        if field == "gc64" then
            local source = launcher.generateSource({entry=entry, dependencies={scripts={}, libraries={}}, lua_version=altered})
            local filename, executable = path.join(root, "launcher.c"), path.join(root, "wrong" .. static.executable_suffix)
            assert(fs.writeFile(filename, source))
            local compiled, output = toolchain.compile(static, filename, executable, {work_dir=root})
            assert(compiled, output)
            local ran, diagnostic, status = process.outputCommand(executable, {}, {LUA_PATH="", LUA_CPATH=""})
            assert(not ran and status and status.code == 70, diagnostic)
            assert(not diagnostic:find("mismatched-runtime-executed", 1, true))
        end
    end
end)
lua_abi.info = original_info
assert(fs.removeTree(root))
assert(success, tostring(failure))
print("LuaJIT runtime mismatch rejection ok")
