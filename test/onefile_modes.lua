--[[
Single-file selection keeps pure Lua in memory and native modules extractable.

Author:
    WaterRun
File:
    onefile_modes.lua
Date:
    2026-10-12
Updated:
    2026-10-12
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("onefile-modes"))
local called, failure = pcall(function()
    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, "assert(arg[1]=='literal & % arg'); print('direct-pure-lua')\n"))
    for _, mode in ipairs({"no-extract", "auto", "extract"}) do
        local built = api.bundle({entry=entry, mode="onefile", onefile_mode=mode,
            out=path.join(root, "app-" .. mode)})
        assert(built.ok, built.error and built.error.message)
        assert(built.onefile_mode == (mode == "auto" and "no-extract" or mode))
        local ran, output = process.outputCommand(built.executable, {"literal & % arg"}, {
            PATH="", LUA_PATH="", LUA_CPATH="", TMPDIR=path.join(root, "missing-temp"),
        })
        if mode ~= "extract" then
            assert(ran and output:find("direct-pure-lua", 1, true), output)
            assert(fs.pathType(path.join(root, "missing-temp")) == "missing")
        end
        local exported = path.join(root, "materials-" .. mode)
        assert(fs.makeDirectory(exported))
        local exported_ok, export_output = process.outputCommand(built.executable,
            {"--luainstaller-extract", exported})
        assert(exported_ok, export_output)
        exported = export_output:match("^%s*(.-)%s*$")
        assert(fs.pathType(path.join(exported, ".luai/build/launcher.c")) == "file")
        assert(fs.pathType(path.join(exported, ".luai/build/RELINKING.adoc")) == "file")
    end
end)
assert(fs.removeTree(root))
assert(called, failure)
print("single-file modes ok")
