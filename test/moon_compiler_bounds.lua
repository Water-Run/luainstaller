--[[
Compiler failures, deadlines and quotas preserve outputs and release workspaces.

Author:
    WaterRun
File:
    moon_compiler_bounds.lua
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
local moon = require("luainstaller.moon")
local root = assert(fs.makePrivateDirectory("moon-compiler-bounds"))
local entry, output = path.join(root, "main.moon"), path.join(root, "existing-output")
assert(fs.writeFile(entry, 'print "moon"\n'))
assert(fs.makeDirectory(output))
assert(fs.writeFile(path.join(output, "user-file"), "keep this output"))
local find_compiler, output_command, make_private = moon.findCompiler, process.outputCommand, fs.makePrivateDirectory
local workspaces, compiler_input = {}, nil
fs.makePrivateDirectory = function(prefix, ...)
    local directory, error_value = make_private(prefix, ...)
    if prefix == "moon-work" and directory then workspaces[#workspaces + 1] = directory end
    return directory, error_value
end
local called, failure = pcall(function()
    local cases = {
        {name="nonzero", code='io.write(INPUT .. ": compiler rejected input"); os.exit(19)',
            kind="MoonScriptCompilationError", reason="exit", status=19},
        {name="output", code='io.write(string.rep("x", 4096))',
            kind="ResourceLimitExceededError", resource="compiled-source-bytes"},
        {name="deadline", code='while true do end', kind="MoonScriptCompilationError", reason="timeout"},
        {name="syntax", code='io.write("local = invalid")', kind="LuaSyntaxError"},
        {name="aggregate", code=[[io.write('print("compiled-source")')]],
            kind="ResourceLimitExceededError", resource="preprocessed-bytes", bundle_limit=24},
    }
    for _, case in ipairs(cases) do
        moon.findCompiler = function() return "luai-compiler-boundary-fixture" end
        process.outputCommand = function(executable, arguments, environment, options)
            if executable ~= "luai-compiler-boundary-fixture" then
                return output_command(executable, arguments, environment, options)
            end
            compiler_input = arguments[2]
            assert(options.working_directory and fs.pathType(options.working_directory) == "directory")
            assert(options.max_output_bytes == 512, "MoonScript output quota was omitted")
            local bounded = {}
            for key, value in pairs(options) do bounded[key] = value end
            bounded.timeout_seconds = 1
            local code = case.code:gsub("INPUT", function() return string.format("%q", compiler_input) end)
            return output_command(harness.lua_command(), {"-e", code .. "; os.exit(0)"},
                environment, bounded)
        end
        local response = api.bundle({entry=entry, out=output, max_source_bytes=512,
            max_bundle_bytes=case.bundle_limit or 4096})
        assert(not response.ok and response.error.type == case.kind,
            case.name .. ": " .. tostring(response.error and response.error.type)
                .. ": " .. tostring(response.error and response.error.output))
        if case.reason then
            assert(response.error.command_status.reason == case.reason, case.name .. " lost the process reason")
        end
        if case.status then assert(response.error.command_status.code == case.status) end
        if case.resource then assert(response.error.resource == case.resource) end
        if case.name == "nonzero" then
            assert(response.error.output:find(entry, 1, true), "compiler diagnostics lost the original input path")
            assert(not response.error.output:find(compiler_input, 1, true), "compiler diagnostics leaked the snapshot path")
        end
        assert(fs.readFile(path.join(output, "user-file")) == "keep this output",
            case.name .. " changed an existing output")
        for _, workspace in ipairs(workspaces) do
            assert(fs.pathType(workspace) == "missing", case.name .. " left a preprocessing workspace")
        end
    end
    moon.findCompiler = function() error("oversized source reached compiler detection", 0) end
    process.outputCommand = output_command
    assert(fs.writeFile(entry, string.rep("x", 129)))
    local response = api.analyze({entry=entry, max_source_bytes=128})
    assert(not response.ok and response.error.type == "ResourceLimitExceededError"
        and response.error.resource == "source-bytes", "the source quota ran after compiler detection")
end)
moon.findCompiler, process.outputCommand, fs.makePrivateDirectory = find_compiler, output_command, make_private
for _, workspace in ipairs(workspaces) do
    if fs.pathType(workspace) == "directory" then assert(fs.removeTree(workspace)) end
end
assert(fs.removeTree(root))
assert(called, failure)
print("MoonScript compiler failure and resource boundaries ok")
