--[[
Run bundles in a private Linux filesystem containing no installed Lua.

Author:
    WaterRun
File:
    no_lua_target.lua
Date:
    2026-10-06
Updated:
    2026-10-06
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")
local config, config_err = toolchain.resolve()
assert(config, config_err and config_err.error.message)
assert(config.host.os == "linux", "this filesystem isolation test requires native Linux")

local root = assert(fs.makePrivateDirectory("no-lua-target"))
local function run()
    local target = path.join(root, "target")
    for _, directory in ipairs({ "bin", "usr", "lib", "lib64", "tmp", "proc", "dev" }) do
        assert(fs.makeDirectory(path.join(target, directory)))
    end
    local source = path.join(root, "source")
    assert(fs.makeDirectory(source))
    assert(toolchain.writeLuaHeader(config, source).ok)
    local module_source = path.join(source, "native_probe.c")
    local module = path.join(source, "native_probe.so")
    assert(fs.writeFile(module_source, [[
#include "lua_min.h"
int luaopen_native_probe(lua_State *L) { lua_pushliteral(L, "native-clean-ok"); return 1; }
]]))
    local compiled, compile_output = toolchain.compileNativeModule(config, module_source, module,
        { work_dir = source })
    assert(compiled, compile_output)
    assert(fs.writeFile(path.join(source, "helper.lua"), "return 'pure-clean-ok'\n"))
    local entry = path.join(source, "main.lua")
    assert(fs.writeFile(entry, [[
assert(require('helper') == 'pure-clean-ok')
assert(require('native_probe') == 'native-clean-ok')
assert(arg[1] == 'space value' and arg[2] == '' and arg[3] == "quote'value")
local file = assert(io.open('/tmp/application-data', 'w'))
assert(file:write('clean target')); assert(file:close())
print('no-lua-target-ok ' .. _VERSION)
]]))
    local built = {}
    for _, mode in ipairs({ "onedir", "onefile" }) do
        built[mode] = require("luainstaller").bundle({
            entry = entry, out = path.join(target, mode), mode = mode,
        })
        assert(built[mode].ok, built[mode].error and built[mode].error.message)
    end

    local copied = {}
    local function copy_system(source_path, destination)
        destination = destination or source_path
        if copied[destination] then return end
        assert(not path.basename(destination):lower():find("lua", 1, true),
            "a system Lua file would enter the clean target: " .. destination)
        local ok, resolved = process.outputCommand("readlink", { "-f", source_path })
        assert(ok, resolved)
        resolved = resolved:gsub("[\r\n]+$", "")
        local output = path.join(target, destination:gsub("^/", ""))
        assert(fs.makeDirectory(path.dirname(output)))
        assert(fs.copyFile(resolved, output))
        assert(fs.setExecutable(output))
        copied[destination] = true
    end
    local function copy_dependencies(binary)
        local ok, output = process.outputCommand("ldd", { binary }, { LC_ALL = "C" })
        assert(ok, output)
        assert(not output:find("not found", 1, true), output)
        for line in output:gmatch("[^\r\n]+") do
            local dependency = line:match("=>%s+(/.-)%s+%(") or line:match("^%s*(/.-)%s+%(")
            if dependency and not path.isWithin(dependency, target) then copy_system(dependency) end
        end
    end
    for _, command in ipairs({ "sh", "find" }) do
        local ok, located = process.outputCommand("sh", { "-c", "command -v \"$1\"", "sh", command })
        assert(ok, located)
        located = located:gsub("[\r\n]+$", "")
        copy_system(located, "/bin/" .. command)
        copy_dependencies(located)
    end
    copy_dependencies(built.onedir.executable)
    copy_dependencies(built.onefile.executable)
    copy_dependencies(module)
    if config.link_mode == "shared" then copy_dependencies(config.runtime_path) end
    local inventory = {}
    for destination in pairs(copied) do inventory[#inventory + 1] = destination end
    table.sort(inventory)
    print("clean target system files:\n" .. table.concat(inventory, "\n"))
    assert(fs.removeTree(source))

    local check = [[
set -eu
PATH=/bin:/usr/bin
export PATH
for command in lua lua5.1 lua5.2 lua5.3 lua5.4 lua5.5 luajit luarocks; do
    if command -v "$command"; then echo "unexpected Lua command: $command" >&2; exit 1; fi
done
unexpected=$(find /bin /usr /lib /lib64 -iname '*lua*')
test -z "$unexpected" || { echo "$unexpected" >&2; exit 1; }
echo 'verified: no installed Lua interpreter, library, headers or LuaRocks'
/onedir/onedir 'space value' '' "quote'value"
/onefile 'space value' '' "quote'value"
/onefile 'space value' '' "quote'value"
]]
    assert(fs.writeFile(path.join(target, "check.sh"), check))
    local available = process.outputCommand("sh", { "-c", "command -v bwrap" })
    local command, arguments
    if available then
        command = "bwrap"
        arguments = { "--unshare-all", "--die-with-parent", "--clearenv",
            "--ro-bind", target, "/", "--proc", "/proc", "--dev", "/dev", "--tmpfs", "/tmp",
            "--setenv", "PATH", "/bin:/usr/bin", "--setenv", "TMPDIR", "/tmp",
            "--chdir", "/", "/bin/sh", "/check.sh" }
    else
        command = "unshare"
        arguments = { "--user", "--map-root-user", "--mount", "--pid", "--fork", "--net",
            "sh", "-c", [[
set -eu
mount --make-rprivate /
mount --rbind /dev "$1/dev"
mount -t proc proc "$1/proc"
exec /usr/sbin/chroot "$1" /bin/sh /check.sh
]], "sh", target }
    end
    local ran, output = process.outputCommand(command, arguments, {
        LUA_PATH = "", LUA_CPATH = "", LUA_INIT = "",
        LUA_INIT_5_1 = "", LUA_INIT_5_2 = "", LUA_INIT_5_3 = "", LUA_INIT_5_4 = "", LUA_INIT_5_5 = "",
    })
    assert(ran, "clean target isolation failed (required test): " .. tostring(output))
    local _, count = output:gsub("no%-lua%-target%-ok", "")
    assert(count == 3, output)
    io.write(output)
    local removed = config.link_mode == "shared"
        and path.join(target, "onedir/.luai/native/" .. config.runtime_name)
        or path.join(target, "onedir/.luai/native/native_probe.so")
    assert(fs.removeFile(removed))
    local fallback_ran, fallback_output = process.outputCommand(command, arguments)
    assert(not fallback_ran, "clean target found a fallback after removing a bundled dependency")
    assert(not fallback_output:find("no-lua-target-ok", 1, true), fallback_output)
    print("negative control passed: removing a bundled dependency prevents execution")
end

local ok, failure = xpcall(run, debug.traceback)
assert(fs.removeTree(root))
assert(ok, failure)
print("no Lua target filesystem passed: " .. _VERSION)
