--[[
MoonScript snapshots and preferred sources do not encode build locations.

Author:
    WaterRun
File:
    moon_reproducibility.lua
Date:
    2026-10-13
Updated:
    2026-10-13
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("moon-reproducibility"))
local called, failure = pcall(function()
    local artifacts, projects = {}, {}
    for index, checkout in ipairs({"checkout-a", "checkout-b"}) do
        local project = path.join(root, checkout .. "/project")
        assert(fs.makeDirectory(project))
        assert(fs.writeFile(path.join(project, "main.moon"),
            'greet = require "greet"\nprint greet arg[1]\n'))
        assert(fs.writeFile(path.join(project, "greet.moon"),
            'return (name) -> "moon-repro " .. name\n'))
        local built = api.bundle({entry=path.join(project, "main.moon"),
            out=path.join(project, "dist/app"), mode="onefile", onefile_mode="no-extract"})
        assert(built.ok, built.error and (built.error.message .. "\n" .. tostring(built.error.output)))
        artifacts[index], projects[index] = built.executable, project
    end
    local bytes = assert(fs.readRegularFile(artifacts[1]))
    assert(bytes == fs.readRegularFile(artifacts[2]), "MoonScript artifacts differ across checkout roots")
    for _, project in ipairs(projects) do
        assert(not bytes:find(project, 1, true), "MoonScript artifact contains a build path")
        assert(not bytes:find(project:gsub("/", "\\"), 1, true), "MoonScript artifact contains a Windows build path")
    end
    for _, executable in ipairs(artifacts) do
        local ran, output = process.outputCommand(executable, {"independent"},
            {PATH="", LUA_PATH="", LUA_CPATH="", TMPDIR=path.join(root, "unwritable-temp")})
        assert(ran and output == "moon-repro independent\n", output)
    end
    local destination = path.join(root, "materials")
    assert(fs.makeDirectory(destination))
    local exported, output = process.outputCommand(artifacts[1], {"--luainstaller-extract", destination})
    assert(exported, output)
    local material_root = output:match("^%s*(.-)%s*$")
    for _, name in ipairs({"main.moon", "greet.moon"}) do
        assert(fs.readFile(path.join(material_root, ".luai/build/moon_sources/" .. name))
            == fs.readFile(path.join(projects[1], name)), "exported preferred MoonScript source changed")
    end
    print("MoonScript artifact SHA-256: " .. hash.sha256(bytes))
end)
assert(fs.removeTree(root))
assert(called, failure)
print("MoonScript reproducibility and preferred sources ok")
