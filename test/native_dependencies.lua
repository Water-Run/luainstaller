--[[
Native dependency diagnostics, including unresolved and transitive libraries.

Author:
    WaterRun
File:
    native_dependencies.lua
Date:
    2026-10-05
Updated:
    2026-10-06
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")
local logger = require("luainstaller.logger")

local original_output = process.outputCommand
local original_type = fs.pathType
local inspected = {}
local replies = {
    ["/fixture/module.so"] = [[
    libfirst.so => /fixture/libfirst.so (0x001)
    libmissing.so => not found
    libstdc++.so.6 => /fixture/libstdc++.so.6 (0x002)
    libc.so.6 => /lib/libc.so.6 (0x003)
    libm.so.6 => /lib/libm.so.6 (0x004)
    /lib64/ld-linux-x86-64.so.2 (0x005)
    liblua.so.5.4 => /fixture/liblua.so.5.4 (0x006)
]],
    ["/fixture/libfirst.so"] = [[
    libsecond.so => /fixture/space dir/libsecond.so (0x007)
    libpthread.so.0 => /lib/libpthread.so.0 (0x008)
]],
    ["/fixture/space dir/libsecond.so"] = [[
    libfirst.so => /fixture/libfirst.so (0x009)
    libgcc_s.so.1 => /fixture/libgcc_s.so.1 (0x010)
]],
    ["/fixture/libstdc++.so.6"] = "libc.so.6 => /lib/libc.so.6 (0x011)\n",
    ["/fixture/libgcc_s.so.1"] = "libc.so.6 => /lib/libc.so.6 (0x011)\n",
}
process.outputCommand = function(command, arguments)
    assert(command == "ldd", "unexpected Linux dependency tool: " .. command)
    local binary = arguments[1]
    inspected[binary] = (inspected[binary] or 0) + 1
    return replies[binary] ~= nil, replies[binary] or "tool unavailable"
end
fs.pathType = function(candidate)
    return replies[candidate] and "file" or original_type(candidate)
end
local checked = toolchain.inspectNativeDependencies({ host = { os = "linux" } },
    "/fixture/module.so", { bundled_libraries = { ["liblua.so.5.4"] = true } })
assert(checked.ok and checked.checked)
local by_name = {}
for _, dependency in ipairs(checked.dependencies) do by_name[dependency.name] = dependency end
assert(by_name["libfirst.so"] and by_name["libsecond.so"])
assert(by_name["libmissing.so"].missing == true)
assert(by_name["libsecond.so"].path == "/fixture/space dir/libsecond.so")
assert(by_name["libstdc++.so.6"] and by_name["libgcc_s.so.1"],
    "C/C++ runtime dependencies were silently filtered")
assert(not by_name["libc.so.6"] and not by_name["libm.so.6"]
    and not by_name["libpthread.so.0"] and not by_name["ld-linux-x86-64.so.2"]
    and not by_name["liblua.so.5.4"], "platform or bundled runtime was reported")
assert(inspected["/fixture/libfirst.so"] == 1, "dependency cycle was traversed again")

process.outputCommand = function(command, arguments)
    assert(command == "ldd")
    if arguments[1] == "/fixture/missing.so" then
        return true, [[
    libm.so.6 => not found
    libnsl.so.2 => not found
    libnsl.so.3 => /fixture/libnsl.so.3 (0x001)
]]
    end
    return true, "libc.so.6 => /lib/libc.so.6 (0x002)\n"
end
local missing_system = toolchain.inspectNativeDependencies({ host = { os = "linux" } },
    "/fixture/missing.so")
by_name = {}
for _, dependency in ipairs(missing_system.dependencies) do by_name[dependency.name] = dependency end
assert(missing_system.checked and by_name["libm.so.6"] and by_name["libm.so.6"].missing,
    "missing system library was filtered")
assert(by_name["libnsl.so.2"] and by_name["libnsl.so.2"].missing,
    "missing libnsl dependency was filtered")
assert(by_name["libnsl.so.3"] and not by_name["libnsl.so.3"].missing,
    "separately distributed libnsl was treated as a baseline system library")

-- A large but finite dependency graph still needs its complete closure.
process.outputCommand = function(command, arguments)
    assert(command == "ldd")
    local index = tonumber(arguments[1]:match("/libchain%-(%d+)%.so$"))
    assert(index)
    if index == 140 then return true, "statically linked\n" end
    return true, string.format("libchain-%d.so => /fixture/libchain-%d.so (0x001)\n",
        index + 1, index + 1)
end
local chain = toolchain.inspectNativeDependencies({ host = { os = "linux" } },
    "/fixture/libchain-0.so")
assert(chain.ok and chain.checked and #chain.dependencies == 140,
    "finite dependency graph was truncated: " .. tostring(#chain.dependencies))

process.outputCommand = function() return false, "ldd unavailable" end
local unchecked = toolchain.inspectNativeDependencies({ host = { os = "linux" } }, "module.so")
assert(unchecked.ok and not unchecked.checked and unchecked.reason)
process.outputCommand = function() error("dependency inspection exploded") end
unchecked = toolchain.inspectNativeDependencies({ host = { os = "linux" } }, "module.so")
assert(unchecked.ok and not unchecked.checked, "inspection exception escaped")
process.outputCommand = function() error("Windows dependency scan must not run") end
unchecked = toolchain.inspectNativeDependencies({ host = { os = "windows" } }, "module.dll")
assert(unchecked.ok and not unchecked.checked)
harness.assert_contains(unchecked.reason, "Windows")

-- Exercise macOS install names and loader-relative/transitive rpaths without
-- treating these parser fixtures as evidence from a native Mac.
local mac_files = {
    ["/fixture/module.so"] = [[
/fixture/module.so:
    @rpath/libfirst.dylib (compatibility version 1.0.0, current version 1.0.0)
    /usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1.0.0)
    /System/Library/Frameworks/CoreFoundation.framework/CoreFoundation (compatibility version 1.0.0, current version 1.0.0)
]],
    ["/fixture/libs/libfirst.dylib"] = [[
/fixture/libs/libfirst.dylib:
    @rpath/libfirst.dylib (compatibility version 1.0.0, current version 1.0.0)
    @loader_path/libsecond.dylib (compatibility version 1.0.0, current version 1.0.0)
    @rpath/libmissing.dylib (compatibility version 1.0.0, current version 1.0.0)
]],
    ["/fixture/libs/libsecond.dylib"] = "/fixture/libs/libsecond.dylib:\n",
}
process.outputCommand = function(command, arguments)
    assert(command == "otool")
    if arguments[1] == "-l" then
        return true, "cmd LC_RPATH\n path @loader_path/libs (offset 12)\n"
    end
    if arguments[1] == "-D" then
        return true, arguments[2] .. ":\n@rpath/" .. path.basename(arguments[2]) .. "\n"
    end
    return mac_files[arguments[2]] ~= nil, mac_files[arguments[2]] or "otool unavailable"
end
fs.pathType = function(candidate) return mac_files[candidate] and "file" or "missing" end
local mac = toolchain.inspectNativeDependencies({ host = { os = "macos" } }, "/fixture/module.so")
assert(mac.ok and mac.checked)
by_name = {}
for _, dependency in ipairs(mac.dependencies) do by_name[dependency.name] = dependency end
assert(by_name["@rpath/libfirst.dylib"].path == "/fixture/libs/libfirst.dylib")
assert(by_name["@loader_path/libsecond.dylib"].path == "/fixture/libs/libsecond.dylib")
assert(by_name["@rpath/libmissing.dylib"].missing == true)
assert(#mac.dependencies == 3, "macOS system libraries or self install name was reported")
process.outputCommand, fs.pathType = original_output, original_type

local config, config_err = toolchain.resolve()
assert(config, config_err and config_err.error.message)
local root = assert(fs.makePrivateDirectory("native-dependencies"))
local entry = path.join(root, "main.lua")
local warnings = {}
local original_warning = logger.logWarning
logger.logWarning = function(source, action, message, details)
    warnings[#warnings + 1] = { source = source, action = action, message = message, details = details }
    return false, "diagnostic log is unwritable"
end
assert(fs.writeFile(entry, "print('pure-lua')\n"))
local pure = require("luainstaller").bundle({ entry = entry, out = path.join(root, "pure") })
assert(pure.ok, pure.error and pure.error.message)
assert(#warnings == 0 and #(pure.warnings or {}) == 0, "pure Lua build emitted native warnings")

if config.host.os == "linux" then
    local second = path.join(root, "libluai-second.so")
    local first = path.join(root, "libluai-first.so")
    local module = path.join(root, "native_dep.so")
    local function compile(name, source, flags)
        local c_path = path.join(root, name .. ".c")
        assert(fs.writeFile(c_path, source))
        local args = { "-shared", "-fPIC", c_path, "-o", path.join(root, name .. ".so") }
        for _, flag in ipairs(flags or {}) do args[#args + 1] = flag end
        local ok, output = process.outputCommand(config.cc, args, config.environment)
        assert(ok, output)
    end
    compile("libluai-second", "int luai_second(void) { return 17; }\n",
        { "-Wl,-soname,libluai-second.so" })
    compile("libluai-first", "extern int luai_second(void); int luai_first(void) { return luai_second(); }\n",
        { second, "-Wl,-soname,libluai-first.so", "-Wl,-rpath," .. root })
    compile("native_dep", "extern int luai_first(void); int luaopen_native_dep(void *L) { (void)L; return luai_first(); }\n",
        { first, "-Wl,-rpath," .. root })
    local real = toolchain.inspectNativeDependencies(config, module)
    assert(real.ok and real.checked and #real.dependencies == 2)
    assert(fs.removeFile(second))
    assert(fs.writeFile(entry, "if arg[1] == 'load' then require('native_dep') end\nprint('native-warn-ok')\n"))
    for _, mode in ipairs({ "onedir", "onefile" }) do
        local built = require("luainstaller").bundle({
            entry = entry, out = path.join(root, mode), mode = mode,
        })
        assert(built.ok, built.error and built.error.message)
        assert(#built.warnings == 1 and #warnings >= 1)
        local warning = built.warnings[1]
        assert(warning.module == module)
        harness.assert_contains(warning.message, "libluai-first.so")
        harness.assert_contains(warning.message, "libluai-second.so")
        harness.assert_contains(warning.message, "Install")
        local missing = false
        for _, dependency in ipairs(warning.dependencies) do
            if dependency.name == "libluai-second.so" then missing = dependency.missing end
        end
        assert(missing, "missing transitive library was not marked")
        local ran, output = process.outputCommand(built.executable, {}, { LUA_PATH = "", LUA_CPATH = "" })
        assert(ran and output:find("native-warn-ok", 1, true), output)
    end
    local code, output, diagnostic = harness.invoke_cli("luai", {
        "-b", entry, "-o", path.join(root, "cli"),
    })
    assert(code == 0, diagnostic)
    harness.assert_contains(output .. diagnostic, "libluai-second.so")

    -- A copied Lua module does not make its SONAME discoverable by the OS
    -- loader. Its original RUNPATH can still point outside the bundle.
    local nested = path.join(root, "nested")
    assert(fs.makeDirectory(nested))
    assert(fs.makeDirectory(path.join(nested, "pkg")))
    assert(toolchain.writeLuaHeader(config, nested).ok)
    local helper = path.join(nested, "pkg/helper.so")
    local dependent = path.join(nested, "dependent.so")
    local helper_c = path.join(nested, "helper.c")
    local dependent_c = path.join(nested, "dependent.c")
    assert(fs.writeFile(helper_c, [[
#include "lua_min.h"
int helper_value(void) { return 42; }
int luaopen_pkg_helper(lua_State *L) { lua_pushliteral(L, "helper-ok"); return 1; }
]]))
    assert(fs.writeFile(dependent_c, [[
#include "lua_min.h"
extern int helper_value(void);
int luaopen_dependent(lua_State *L) { lua_pushfstring(L, "%d", helper_value()); return 1; }
]]))
    local compiled, compile_output = process.outputCommand(config.cc,
        { "-shared", "-fPIC", helper_c, "-Wl,-soname,helper.so", "-o", helper }, config.environment)
    assert(compiled, compile_output)
    compiled, compile_output = process.outputCommand(config.cc,
        { "-shared", "-fPIC", dependent_c, helper, "-Wl,-rpath," .. path.join(nested, "pkg"),
            "-o", dependent }, config.environment)
    assert(compiled, compile_output)
    local nested_entry = path.join(nested, "main.lua")
    assert(fs.writeFile(nested_entry,
        "assert(require('dependent') == '42'); assert(require('pkg.helper') == 'helper-ok')\n"))
    local nested_bundles = {}
    for _, mode in ipairs({ "onedir", "onefile" }) do
        local built = require("luainstaller").bundle({
            entry = nested_entry, out = path.join(nested, mode), mode = mode,
        })
        assert(built.ok, built.error and built.error.message)
        assert(#built.warnings == 1, "copied module basename hid an external loader dependency")
        assert(built.warnings[1].module == dependent)
        harness.assert_contains(built.warnings[1].message, "helper.so")
        local ran, output = process.outputCommand(built.executable, {}, { LUA_PATH = "", LUA_CPATH = "" })
        assert(ran, output)
        nested_bundles[#nested_bundles + 1] = built
    end
    assert(fs.removeFile(helper))
    for _, built in ipairs(nested_bundles) do
        local ran, output = process.outputCommand(built.executable, {}, {
            LUA_PATH = "", LUA_CPATH = "", LD_LIBRARY_PATH = "",
        })
        assert(not ran, "fixture unexpectedly found its removed external dependency")
        harness.assert_contains(output, "helper.so")
    end
elseif config.host.os == "windows" then
    local c_path = path.join(root, "native_dep.c")
    local module = path.join(root, "native_dep.dll")
    assert(fs.writeFile(c_path, [[
#include "lua_min.h"
__declspec(dllexport) int luaopen_native_dep(lua_State *L) {
    lua_pushliteral(L, "native-warn-ok");
    return 1;
}
]]))
    local compiled, compile_output = toolchain.compileNativeModule(config, c_path, module, { work_dir = root })
    assert(compiled, compile_output)
    assert(fs.writeFile(entry, "print(require('native_dep'))\n"))
    for _, mode in ipairs({ "onedir", "onefile" }) do
        local built = require("luainstaller").bundle({
            entry = entry, out = path.join(root, mode), mode = mode,
        })
        assert(built.ok, built.error and built.error.message)
        assert(#built.warnings == 1 and built.warnings[1].checked == false)
        harness.assert_contains(built.warnings[1].message, "Windows DLL dependencies were not checked")
        local ran, output = process.outputCommand(built.executable, {}, { LUA_PATH = "", LUA_CPATH = "" })
        assert(ran and output:find("native-warn-ok", 1, true), output)
    end
end
logger.logWarning = original_warning
assert(fs.removeTree(root))
print("native dependency diagnostics ok: " .. _VERSION)
