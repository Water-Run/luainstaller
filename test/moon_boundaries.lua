--[[
MoonScript preserves exclusion semantics and the first entry snapshot.

Author:
    WaterRun
File:
    moon_boundaries.lua
Date:
    2026-10-13
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local moon = require("luainstaller.moon")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("moon-boundaries"))
local outputs = assert(fs.makePrivateDirectory("moon-manual-outputs"))
local entry = path.join(root, "main.moon")
local module = path.join(root, "greet.moon")
local find_compiler = moon.findCompiler
local called, failure = pcall(function()
    assert(fs.writeFile(entry, 'value = require "greet"\nprint value\n'))
    assert(fs.writeFile(module, 'return require "leaf"\n'))
    assert(fs.writeFile(path.join(root, "leaf.moon"), 'return "leaf"\n'))
    assert(fs.writeFile(path.join(root, "ignored.moon"), 'if true\n  (\n'))
    for _, excluded in ipairs({module, "greet.moon"}) do
        local analyzed = api.analyze({entry=entry, exclude={excluded, "ignored.moon"}})
        assert(analyzed.ok, analyzed.error and (analyzed.error.type .. ": " .. analyzed.error.message))
        assert(#analyzed.dependencies.scripts == 1 and analyzed.dependencies.scripts[1] == path.join(root, "leaf.moon"),
            "excluding a required Moon module changed transitive discovery")
    end
    for _, options in ipairs({{discovery_mode="manual"}, {depscan=false}}) do
        options.entry, options.include = entry, {module}
        local manual = api.analyze(options)
        assert(manual.ok, manual.error and (manual.error.type .. ": " .. manual.error.message))
        assert(#manual.dependencies.scripts == 1 and manual.dependencies.scripts[1] == module,
            "manual MoonScript discovery included an unrequested module")
    end
    assert(fs.writeFile(path.join(root, "unused.lua"), 'return "unused Lua"\n'))
    assert(fs.writeFile(path.join(root, "unused.moon"), 'invalid unused MoonScript !\n'))
    local manual_collision = api.analyze({entry=entry, discovery_mode="manual", include={module}})
    assert(manual_collision.ok, "unselected files prevented manual discovery: "
        .. tostring(manual_collision.error and manual_collision.error.message))
    for _, mode in ipairs({"onedir", "extract", "no-extract"}) do
        local built = api.bundle({entry=entry, discovery_mode="manual",
            include={module, path.join(root, "leaf.moon")}, out=path.join(outputs, mode),
            mode=mode == "onedir" and "onedir" or "onefile",
            onefile_mode=mode == "onedir" and "auto" or mode})
        assert(built.ok, built.error and built.error.message)
        local ran, output = process.outputCommand(built.executable, {}, {LUA_PATH="", LUA_CPATH=""})
        assert(ran and output == "leaf\n", output)
        if mode ~= "onedir" then assert(built.onefile_mode == mode) end
    end
    assert(fs.removeFile(path.join(root, "unused.lua")))
    assert(fs.removeFile(path.join(root, "unused.moon")))
    assert(fs.removeFile(path.join(root, "ignored.moon")))
    assert(fs.writeFile(path.join(root, "shadowed.moon"), 'invalid excluded MoonScript !\n'))
    assert(fs.writeFile(path.join(root, "shadowed.lua"), 'return "Lua takes its own path"\n'))
    assert(fs.writeFile(entry, 'print require "shadowed"\n'))
    local shadowed = api.analyze({entry=entry, exclude={"shadowed.moon"}})
    assert(shadowed.ok and #shadowed.dependencies.scripts == 1
        and shadowed.dependencies.scripts[1] == path.join(root, "shadowed.lua"),
        shadowed.error and shadowed.error.message)
    assert(fs.removeFile(path.join(root, "shadowed.moon")))
    local original = assert(fs.readFile(entry))
    moon.findCompiler = function()
        local compiler, error_value = find_compiler()
        assert(fs.writeFile(entry, 'print "changed during compiler lookup"\n'))
        return compiler, error_value
    end
    local changed = api.analyze({entry=entry})
    moon.findCompiler = find_compiler
    assert(not changed.ok and changed.error.type == "SourceChangedError",
        "a changed entry replaced the first MoonScript snapshot")
    assert(fs.writeFile(entry, original))
end)
moon.findCompiler = find_compiler
assert(fs.removeTree(root))
assert(fs.removeTree(outputs))
assert(called, failure)
print("MoonScript snapshot and exclusion boundaries ok")
