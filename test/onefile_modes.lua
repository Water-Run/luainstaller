--[[
Single-file selection keeps pure Lua in memory and native modules extractable.

Author:
    WaterRun
File:
    onefile_modes.lua
Date:
    2026-10-12
Updated:
    2026-10-13
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")
local root = assert(fs.makePrivateDirectory("onefile-modes"))
local called, failure = pcall(function()
    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, "assert(arg[1]=='literal & % arg'); print('direct-pure-lua')\n"))
    for _, mode in ipairs({"no-extract", "auto", "extract"}) do
        local built = api.bundle({entry=entry, mode="onefile", onefile_mode=mode,
            out=path.join(root, "app-" .. mode)})
        assert(built.ok, built.error and built.error.message)
        assert(built.onefile_mode == (mode == "auto" and "no-extract" or mode))
        assert(type(built.selection_reason) == "string" and built.selection_reason ~= "",
            "single-file selection did not explain its choice")
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
        if mode == "no-extract" then
            local repeated = process.outputCommand(built.executable, {"--luainstaller-extract",
                path.join(root, "materials-" .. mode)})
            assert(not repeated, "material export overwrote an existing exported tree")
            local regenerated, regeneration_output = process.outputCommand(harness.lua_command(), {
                path.join(exported, ".luai/build/generate-onefile-payload.lua"), exported,
                path.join(exported, ".luai/build/payload.inc"),
            }, {}, {timeout_seconds=120})
            assert(regenerated, regeneration_output)
            local static, static_error = toolchain.resolve({require_static=true})
            assert(static, static_error and static_error.error.message)
            if package.config:sub(1, 1) == "\\" then
                static.link_args[#static.link_args + 1] = static.compiler_family == "msvc"
                    and "advapi32.lib" or "-ladvapi32"
            end
            local relinked = path.join(root, "relinked" .. (package.config:sub(1, 1) == "\\" and ".exe" or ""))
            local linked, link_output = toolchain.compile(static, path.join(exported, ".luai/build/no-extract.c"),
                relinked, {work_dir=path.join(exported, ".luai/build")})
            assert(linked, link_output)
            local relink_ran, relink_output = process.outputCommand(relinked, {"literal & % arg"}, {
                PATH="", LUA_PATH="", LUA_CPATH="", TMPDIR=path.join(root, "missing-temp"),
            })
            assert(relink_ran and relink_output:find("direct-pure-lua", 1, true), relink_output)
        end
    end
end)
assert(fs.removeTree(root))
assert(called, failure)
print("single-file modes ok")
