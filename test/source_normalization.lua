--[[
Shebang removal preserves mixed-newline source and its executable meaning.

Author:
    WaterRun
File:
    source_normalization.lua
Date:
    2026-10-15
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local api = require("luainstaller")
local analyzer = require("luainstaller.analyzer")
local runtime = require("luainstaller.runtime")
local cgen = require("luainstaller.cgen")
local compat = require("luainstaller.compat")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local embedded = assert(compat.loadText(cgen.runtimeSource
    .. "\nreturn {stripSource=stripSource, run=run}", "@embedded-normalization"))()

for _, prefix in ipairs({"", "\239\187\191"}) do
    for _, ending in ipairs({"\n", "\r\n", "\r", "\n\r"}) do
        local body = "local value = 41\r\nreturn value + 1\n"
        local source = prefix .. "#!/usr/bin/env lua" .. ending .. body
        local expected = "\n" .. body
        assert(analyzer.prepareSource(source) == expected, "analysis removed code after the shebang")
        for _, implementation in ipairs({runtime, embedded}) do
            assert(implementation.stripSource(source) == expected,
                "runtime removed code after the shebang")
            assert(implementation.run({entry={path="mixed.lua", source=source}}) == 42)
            local failed, message = pcall(implementation.run, {entry={path="mixed.lua",
                source=prefix .. "#!lua" .. ending .. "local value = 41\r\nerror('line-check')\n"}})
            assert(not failed and tostring(message):find("mixed.lua:3:", 1, true),
                "normalization changed source line numbers: " .. tostring(message))
        end
    end
end

local root = assert(fs.makePrivateDirectory("source-normalization"))
local called, failure = pcall(function()
    local entry = path.join(root, "main.lua")
    local dependency = path.join(root, "dependency.lua")
    assert(fs.writeFile(entry, "#!/usr/bin/env lua\nlocal value = require('dependency')\r\n"
        .. "assert(value == 42); print('mixed-newline-ok')\n"))
    assert(fs.writeFile(dependency, "#!lua\nlocal base = 41\r\nreturn base + 1\n"))
    for _, mode in ipairs({"static", "manual", "runtime"}) do
        local analyzed = api.analyze({entry=entry, discovery_mode=mode,
            include=mode == "manual" and {dependency} or nil})
        assert(analyzed.ok, analyzed.error and (analyzed.error.message .. "\n" .. tostring(analyzed.error.output)))
        assert(#analyzed.dependencies.scripts == 1, mode .. " lost the first dependency")
    end
    local outputs = {}
    for _, mode in ipairs({"onedir", "extract", "no-extract"}) do
        local built = api.bundle({entry=entry, out=path.join(root, "app-" .. mode),
            mode=mode == "onedir" and "onedir" or "onefile",
            onefile_mode=mode == "onedir" and "auto" or mode})
        assert(built.ok, built.error and (built.error.message .. "\n" .. tostring(built.error.output)))
        outputs[#outputs + 1] = built.executable
    end
    assert(fs.removeFile(entry))
    assert(fs.removeFile(dependency))
    for _, executable in ipairs(outputs) do
        local ran, output = process.outputCommand(executable, {}, {PATH="", LUA_PATH="", LUA_CPATH=""})
        assert(ran and output:find("mixed-newline-ok", 1, true), output)
    end
end)
assert(fs.removeTree(root))
assert(called, failure)
print("mixed-newline source normalization ok")
