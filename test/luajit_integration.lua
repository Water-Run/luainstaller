--[[
LuaJIT discovery, native linking and standalone artifact integration.

Author:
    WaterRun
File:
    luajit_integration.lua
Date:
    2026-10-15
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
assert(type(jit) == "table", "run this suite with LuaJIT 2.1")
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")
local root = assert(fs.makePrivateDirectory("luajit-integration"))

local function diagnostic(result)
    if result.ok then return "ok" end
    local err = result.error or result
    local parts = { tostring(err.message), tostring(err.module_name or ""), tostring(err.output or err.cause or "") }
    for _, failure in ipairs(err.failures or {}) do
        parts[#parts + 1] = tostring(failure.message) .. ": " .. tostring(failure.output)
    end
    return table.concat(parts, "\n")
end

local success, failure = pcall(function()
    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, [[
local bit = require("bit")
local ffi = require("ffi")
local jit = require("jit")
local util = require("jit.util")
local profile = require("jit.profile")
local buffer = require("string.buffer")
local bc = require("jit.bc")
assert(bit.band(0xff, 0x0f) == 15)
assert(tonumber(42LL + 1ULL) == 43)
assert(type(2i) == "cdata")
assert(type(util.funcinfo) == "function" and type(profile.start) == "function")
assert(buffer.new():put("LuaJIT"):get() == "LuaJIT")
assert(type(bc.line) == "function")
if jit.os == "Windows" then
    ffi.cdef("unsigned long GetCurrentProcessId(void);")
    assert(ffi.C.GetCurrentProcessId() > 0)
else
    ffi.cdef("int abs(int);")
    assert(ffi.C.abs(-42) == 42)
end
if arg[1] == "off" then jit.off() else jit.on() end
local sum = 0
for i = 1, 100000 do sum = sum + i end
assert(sum == 5000050000)
assert(jit.status() == (arg[1] ~= "off"))
print("luajit-bundle-ok", jit.version, arg[1])
]]))
    for _, mode in ipairs({"static", "runtime"}) do
        local analyzed = api.analyze({entry=entry, discovery_mode=mode, max_deps=120})
        assert(analyzed.ok, diagnostic(analyzed))
        assert(#analyzed.dependencies.scripts >= 2, "jit.bc and jit.vmdef must be packaged")
        assert(#analyzed.dependencies.libraries == 0, "LuaJIT builtins are not external C modules")
    end
    local builds = {}
    for _, mode in ipairs({"onedir", "extract", "no-extract", "auto"}) do
        local built = api.bundle({entry=entry, max_deps=120,
            mode=mode == "onedir" and "onedir" or "onefile",
            onefile_mode=mode == "onedir" and "auto" or mode,
            out=path.join(root, "bundle-" .. mode)})
        assert(built.ok, diagnostic(built))
        assert(built.manifest.lua.kind == "luajit")
        assert(built.manifest.lua.runtime_version == jit.version)
        builds[#builds + 1] = built
    end
    assert(fs.removeFile(entry))
    for _, built in ipairs(builds) do
        for _, state in ipairs({"on", "off"}) do
            local ran, output = process.outputCommand(built.executable, {state}, {
                PATH="", LUA_PATH="", LUA_CPATH="",
            })
            assert(ran and output:find("luajit-bundle-ok", 1, true), output)
        end
    end
    local native, err = toolchain.resolve()
    assert(native, diagnostic(err or {}))
    assert(native.lua_version.kind == "luajit" and native.native_module_verified)

    if require("luainstaller.compat").loadText("const value = 1") then
        local extra = path.join(root, "dependency.lua")
        assert(fs.writeFile(extra, "return 42\n"))
        assert(fs.writeFile(entry, [[
local f = require -> require("shadowed")
assert(f(function() return 7 end) == 7)
local value = require("dependency")
assert(value == 42)
print("luajit-short-function-ok")
]]))
        local unsupported = api.analyze({entry=entry})
        assert(not unsupported.ok and unsupported.error.type == "DiscoveryError")
        local outputs = {}
        for _, mode in ipairs({"runtime", "manual"}) do
            local built = api.bundle({entry=entry, discovery_mode=mode, include={extra},
                mode="onefile", onefile_mode="no-extract", out=path.join(root, "syntax-" .. mode)})
            assert(built.ok, diagnostic(built))
            outputs[#outputs + 1] = built.executable
        end
        assert(fs.removeFile(entry))
        assert(fs.removeFile(extra))
        for _, executable in ipairs(outputs) do
            local ran, output = process.outputCommand(executable, {}, {PATH="", LUA_PATH="", LUA_CPATH=""})
            assert(ran and output:find("luajit-short-function-ok", 1, true), output)
        end
    end
end)
assert(fs.removeTree(root))
assert(success, type(failure) == "table" and diagnostic(failure) or tostring(failure))
print("LuaJIT standalone integration ok")
