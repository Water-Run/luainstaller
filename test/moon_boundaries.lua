--[[
MoonScript preserves exclusion semantics and the first entry snapshot.

Author:
    WaterRun
File:
    moon_boundaries.lua
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
local moon = require("luainstaller.moon")
local root = assert(fs.makePrivateDirectory("moon-boundaries"))
local entry = path.join(root, "main.moon")
local module = path.join(root, "greet.moon")
local find_compiler = moon.findCompiler
local called, failure = pcall(function()
    assert(fs.writeFile(entry, 'print require "greet"\n'))
    assert(fs.writeFile(module, 'return require "leaf"\n'))
    assert(fs.writeFile(path.join(root, "leaf.moon"), 'return "leaf"\n'))
    assert(fs.writeFile(path.join(root, "ignored.moon"), 'invalid MoonScript !\n'))
    for _, excluded in ipairs({module, "greet.moon"}) do
        local analyzed = api.analyze({entry=entry, exclude={excluded, "ignored.moon"}})
        assert(analyzed.ok, analyzed.error and (analyzed.error.type .. ": " .. analyzed.error.message))
        assert(#analyzed.dependencies.scripts == 1 and analyzed.dependencies.scripts[1] == path.join(root, "leaf.moon"),
            "excluding a required Moon module changed transitive discovery")
    end
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
assert(called, failure)
print("MoonScript snapshot and exclusion boundaries ok")
