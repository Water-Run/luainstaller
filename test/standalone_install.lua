--[[
Exercise offline installation, relocation, library use and clean-target builds.

Author:
    WaterRun
File:
    standalone_install.lua
Date:
    2026-09-22
Updated:
    2026-09-22
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local api = require("luainstaller")
local lua = harness.lua_command()
if lua:find("[/\\]") then lua = path.absolute(lua) end
local windows = package.config:sub(1, 1) == "\\"
local root = assert(fs.makePrivateDirectory("standalone"))
local prefix = path.join(root, "installed tree")
local moved = path.join(root, "relocated tree")
local project = path.join(root, "outside checkout")
assert(fs.makeDirectory(project))
local entry = path.join(project, "main.lua")
assert(fs.writeFile(entry, 'print(require("greeting")(arg[1]))\n'))
assert(fs.writeFile(path.join(project, "greeting.lua"),
    'return function(name) return "standalone " .. (name or "ok") end\n'))
local environment = { LUA_PATH = "", LUA_CPATH = "" }
for minor = 1, 5 do
    environment["LUA_PATH_5_" .. minor] = ""
    environment["LUA_CPATH_5_" .. minor] = ""
end

local function checked(executable, arguments, env)
    local ok, output = process.outputCommand(executable, arguments, env or environment)
    assert(ok, output)
    return output
end

local installer = path.absolute("tools/install.lua")
checked(lua, { installer, "--prefix", prefix, "--lua", lua })
assert(fs.readFile(path.join(prefix, "LICENSE")) == fs.readFile("LICENSE"))
local installed, output = process.outputCommand(lua, { installer, "--prefix", prefix }, environment)
assert(not installed and output:find("destination already exists", 1, true), output)
assert(fs.writeFile(path.join(prefix, "keep.txt"), "preserve me\n"))
installed = process.outputCommand(lua, { installer, "--prefix", prefix }, environment)
assert(not installed and fs.readFile(path.join(prefix, "keep.txt")) == "preserve me\n")
if not windows then
    local alias = path.join(root, "alias")
    assert(process.outputCommand("ln", { "-s", prefix, alias }))
    local alias_ok = process.outputCommand(lua, {
        installer, "--prefix", path.join(alias, "child"),
    }, environment)
    assert(not alias_ok and fs.pathType(path.join(prefix, "child")) == "missing")
    assert(fs.removeFile(alias))

    local failing_lua = path.join(root, "failing-lua")
    assert(fs.writeFile(failing_lua, '#!/bin/sh\nif [ "$1" = -e ]; then printf %s '
        .. process.shellQuote(_VERSION) .. '; else exit 23; fi\n'))
    assert(fs.setExecutable(failing_lua))
    local failed_prefix = path.join(root, "failed-install")
    local failed = process.outputCommand(lua, {
        installer, "--prefix", failed_prefix, "--lua", failing_lua,
    }, environment)
    assert(not failed and fs.pathType(failed_prefix) == "missing")
    for _, item in ipairs(assert(fs.listTree(root))) do
        assert(not item.path:match("^luainstaller%-install%-"), "failed install left staging files")
    end
end
assert(fs.rename(prefix, moved))

local function cli(name, arguments)
    local executable = path.join(moved, "bin/" .. name .. (windows and ".cmd" or ""))
    if windows then
        local function quote(value) return "'" .. value:gsub("'", "''") .. "'" end
        local parts = { "&", quote(executable) }
        for _, value in ipairs(arguments) do parts[#parts + 1] = quote(value) end
        local script = { "Set-Location -LiteralPath " .. quote(project) }
        for key, value in pairs(environment) do
            script[#script + 1] = "$env:" .. key .. "=" .. quote(value)
        end
        script[#script + 1] = table.concat(parts, " ")
        script[#script + 1] = "exit $LASTEXITCODE"
        local ok, output = process.outputPowerShell(table.concat(script, ";"))
        assert(ok, output)
        return output
    end
    local command = { "-c", 'cd "$1" && shift && exec "$@"', "standalone-test", project, executable }
    for _, value in ipairs(arguments) do command[#command + 1] = value end
    return checked("sh", command)
end

assert(cli("luai", { "-v" }) == "luai " .. api.VERSION .. "\n")
assert(cli("luainstaller", { "version" }):find("luainstaller " .. api.VERSION, 1, true))
assert(cli("luai", { "-a", entry }):find("scripts: 1", 1, true))
assert(cli("luainstaller", { "trace", entry, "--lua", lua }):find("greeting", 1, true))
local library_probe = path.join(project, "library.lua")
assert(fs.writeFile(library_probe, string.format([[
package.path = %q
local api = require("luainstaller")
assert(api.VERSION == %q)
assert(api.analyze({ entry = %q }).ok)
print("standalone API ok")
]], path.join(moved, "?.lua"), api.VERSION, entry)))
assert(checked(lua, { library_probe }):find("standalone API ok", 1, true))

local empty = path.join(root, "empty-path")
assert(fs.makeDirectory(empty))
local clean = { PATH = empty, LUA_PATH = "", LUA_CPATH = "" }
for minor = 1, 5 do
    clean["LUA_PATH_5_" .. minor] = ""
    clean["LUA_CPATH_5_" .. minor] = ""
end
for _, mode in ipairs({ "dir", "file" }) do
    local output_path = path.join(root, "artifact-" .. mode .. (windows and mode == "file" and ".exe" or ""))
    cli("luainstaller", { "build", "--" .. mode, entry, "-o", output_path })
    local executable = mode == "dir"
        and path.join(output_path, path.basename(output_path) .. (windows and ".exe" or ""))
        or output_path
    local run_output = checked(executable, { "space & quote\" argument" }, clean)
    assert(run_output:find('standalone space & quote" argument', 1, true), run_output)
    if mode == "dir" then
        assert(fs.readFile(path.join(output_path, ".luai/licenses/Lua-MIT.txt"))
            == fs.readFile("LICENSES/Lua-MIT.txt"))
    end
end
assert(fs.removeTree(root))
print("standalone install, relocation, API, onedir and onefile ok")
