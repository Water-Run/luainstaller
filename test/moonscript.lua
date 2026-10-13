--[[
Real local MoonScript compilation, mixed modules and opt-out behavior.

Author:
    WaterRun
File:
    moonscript.lua
Date:
    2026-10-13
Updated:
    2026-10-13
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("moonscript"))
local external_root = assert(fs.makePrivateDirectory("moon-external-test"))
local make_private = fs.makePrivateDirectory
local workspaces = {}
fs.makePrivateDirectory = function(prefix, ...)
    local directory, error_value = make_private(prefix, ...)
    if prefix == "moon-work" and directory then workspaces[#workspaces + 1] = directory end
    return directory, error_value
end
local entry = path.join(root, "main.moon")
assert(fs.writeFile(entry, 'greet = require "greet"\nplain = require "plain"\nprint greet.message .. plain\n'))
assert(fs.writeFile(path.join(root, "greet.moon"), '{message: "moon-"}\n'))
assert(fs.writeFile(path.join(root, "plain.lua"), 'return "mixed"\n'))
local called, failure = pcall(function()
    local analyzed = api.analyze({entry=entry})
    assert(analyzed.ok, analyzed.error and analyzed.error.message)
    assert(analyzed.entry == entry)
    assert(#analyzed.dependencies.scripts == 2)
    for _, filename in ipairs(analyzed.dependencies.scripts) do
        assert(filename == path.join(root, "greet.moon") or filename == path.join(root, "plain.lua"), filename)
    end
    local built = api.bundle({entry=entry, out=path.join(root, "app")})
    assert(built.ok, built.error and built.error.message)
    local ran, output = process.outputCommand(built.executable, {}, {LUA_PATH="", LUA_CPATH=""})
    assert(ran and output == "moon-mixed\n", output)
    assert(fs.readFile(path.join(built.out, ".luai/build/moon_sources/main.moon")) == fs.readFile(entry))
    assert(fs.readFile(path.join(built.out, ".luai/build/moon_sources/greet.moon"))
        == fs.readFile(path.join(root, "greet.moon")))
    local runtime = api.analyze({entry=entry, discovery_mode="runtime", lua=harness.lua_command()})
    assert(runtime.ok and #runtime.dependencies.scripts == 2, runtime.error and runtime.error.message)
    for _, mode in ipairs({"auto", "extract", "no-extract"}) do
        local single = api.bundle({entry=entry, mode="onefile", onefile_mode=mode,
            out=path.join(root, "single-" .. mode)})
        assert(single.ok, single.error and single.error.message)
        local single_ran, single_output = process.outputCommand(single.executable, {}, {LUA_PATH="", LUA_CPATH=""})
        assert(single_ran and single_output == "moon-mixed\n", single_output)
    end
    local manual_entry = path.join(root, "manual.moon")
    local external = path.join(external_root, "manual_value.moon")
    assert(fs.writeFile(manual_entry, 'name = "manual_value"\nprint (require name)\n'))
    assert(fs.writeFile(external, 'return "external-moon"\n'))
    local manual = api.bundle({entry=manual_entry, discovery_mode="manual", include={external},
        out=path.join(root, "manual-app")})
    assert(manual.ok, manual.error and manual.error.message)
    local manual_ran, manual_output = process.outputCommand(manual.executable, {}, {LUA_PATH="", LUA_CPATH=""})
    assert(manual_ran and manual_output == "external-moon\n", manual_output)
    local excluded = api.analyze({entry=manual_entry, discovery_mode="manual", include={external}, exclude={external}})
    assert(excluded.ok and #excluded.dependencies.scripts == 0, excluded.error and excluded.error.message)
    local ignored = path.join(root, "ignored.moon")
    assert(fs.writeFile(ignored, "this isn't valid MoonScript!\n"))
    local skipped = api.analyze({entry=entry, exclude={ignored}})
    assert(skipped.ok, skipped.error and skipped.error.message)
    assert(fs.removeFile(ignored))
    local moon = require("luainstaller.moon")
    local find_compiler = moon.findCompiler
    local compiler = assert(find_compiler())
    local compiler_dir = path.join(root, "compiler %LUAI_MOON_CANARY% & space")
    assert(fs.makeDirectory(compiler_dir))
    local windows = package.config:sub(1, 1) == "\\"
    local wrapper = path.join(compiler_dir, windows and "moonc.cmd" or "moonc")
    assert(fs.writeFile(wrapper, windows and ('@echo off\r\n"' .. compiler .. '" %*\r\n')
        or ("#!/bin/sh\nexec " .. process.shellQuote(compiler) .. ' "$@"\n')))
    assert(fs.setExecutable(wrapper))
    local unusual_entry = path.join(root, "main %LUAI_MOON_CANARY% & space.moon")
    assert(fs.writeFile(unusual_entry, 'print "literal-moon-path"\n'))
    moon.findCompiler = function() return wrapper end
    local unusual = api.bundle({entry=unusual_entry, out=path.join(root, "unusual-app")})
    moon.findCompiler = find_compiler
    assert(unusual.ok, unusual.error and (unusual.error.message .. "\n" .. tostring(unusual.error.output)))
    local unusual_ran, unusual_output = process.outputCommand(unusual.executable, {}, {LUA_PATH="", LUA_CPATH=""})
    assert(unusual_ran and unusual_output == "literal-moon-path\n", unusual_output)
    local original_source = assert(fs.readFile(path.join(root, "greet.moon")))
    local toolchain = require("luainstaller.toolchain")
    local original_compile = toolchain.compile
    toolchain.compile = function(...)
        local compiled, compiler_output, command = original_compile(...)
        assert(fs.writeFile(path.join(root, "greet.moon"), '{message: "changed-"}\n'))
        return compiled, compiler_output, command
    end
    local changed = api.bundle({entry=entry, out=path.join(root, "changed")})
    toolchain.compile = original_compile
    assert(not changed.ok and changed.error.type == "SourceChangedError",
        changed.error and changed.error.message)
    assert(fs.pathType(path.join(root, "changed")) == "missing", "changed Moon source was published")
    assert(fs.writeFile(path.join(root, "greet.moon"), original_source))
    local original = process.outputCommand
    process.outputCommand = function(executable, ...)
        assert(not tostring(executable):lower():find("moonc", 1, true), "opt-out started a compiler")
        return original(executable, ...)
    end
    local disabled = api.analyze({entry=entry, moon_detect=false})
    process.outputCommand = original
    assert(not disabled.ok and disabled.error.type == "LuaSyntaxError",
        disabled.error and (disabled.error.type .. ": " .. disabled.error.message))
    moon.findCompiler = function() error("disabled or Lua input detected MoonScript", 0) end
    local original_output = process.output
    process.output = function(command, ...)
        assert(not command:find("moonc", 1, true), "disabled or Lua input detected MoonScript")
        return original_output(command, ...)
    end
    assert(api.analyze({entry=path.join(root, "plain.lua")}).ok)
    local disabled_again = api.analyze({entry=entry, moon_detect=false})
    process.output = original_output
    moon.findCompiler = find_compiler
    assert(not disabled_again.ok and disabled_again.error.type == "LuaSyntaxError")
    process.output = function(command, ...)
        if command == "command -v moonc" then return false, "" end
        return original_output(command, ...)
    end
    local missing = api.analyze({entry=entry})
    process.output = original_output
    if package.config:sub(1, 1) == "\\" then
        moon.findCompiler = function()
            return nil, {ok=false, error={type="MoonScriptCompilerNotFoundError",
                message="Install MoonScript: luarocks install moonscript"}}
        end
        missing = api.analyze({entry=entry})
        moon.findCompiler = find_compiler
    end
    assert(not missing.ok and missing.error.type == "MoonScriptCompilerNotFoundError")
    assert(missing.error.message:find("luarocks install moonscript", 1, true))
    moon.findCompiler = function() return harness.lua_command() end
    local bad_compiler = api.analyze({entry=entry})
    moon.findCompiler = find_compiler
    assert(not bad_compiler.ok and bad_compiler.error.type == "MoonScriptCompilationError")
    assert(fs.writeFile(path.join(root, "greet.lua"), 'return {}\n'))
    local collision = api.analyze({entry=entry})
    assert(not collision.ok and collision.error.type == "MoonScriptCollisionError")
end)
fs.makePrivateDirectory = make_private
for _, directory in ipairs(workspaces) do
    assert(fs.pathType(directory) == "missing", "MoonScript operation left its workspace: " .. directory)
end
assert(fs.removeTree(root))
assert(fs.removeTree(external_root))
assert(called, failure)
print("real MoonScript preprocessing ok")
