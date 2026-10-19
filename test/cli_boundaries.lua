--[[
Behavioral regressions for CLI argument and output boundaries.

Author:
    WaterRun
File:
    cli_boundaries.lua
Date:
    2026-10-19
Updated:
    2026-10-19
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local cli = require("luainstaller.cli")
local api = require("luainstaller")
local logger = require("luainstaller.logger")
local present = require("luainstaller.cli_present")
local failures = {}

local function check(name, operation)
    local ok, err = pcall(operation)
    if not ok then failures[#failures + 1] = name .. ": " .. tostring(err) end
end

local function invoke(program, args, color)
    local stdout, stderr = {}, {}
    local original = io
    local fake = {}
    for key, value in pairs(original) do fake[key] = value end
    fake.write = function(...)
        for index = 1, select("#", ...) do
            stdout[#stdout + 1] = tostring(select(index, ...))
        end
    end
    fake.stderr = {write = function(_, ...)
        for index = 1, select("#", ...) do
            stderr[#stderr + 1] = tostring(select(index, ...))
        end
    end}
    _G.io = fake
    local called, code = pcall(cli.main, args, {
        program_name = program, color = color or false, animations = false,
    })
    _G.io = original
    assert(called, code)
    return code, table.concat(stdout), table.concat(stderr)
end

local function with_analysis(operation)
    local original = api.analyze
    local captured
    api.analyze = function(options)
        captured = options
        return {ok = true, entry = options.entry,
            dependencies = {scripts = {}, libraries = {}}, trace = {}}
    end
    local ok, err = pcall(operation, function() return captured end)
    api.analyze = original
    assert(ok, err)
end

for _, program in ipairs({"luai", "luainstaller"}) do
    local action = program == "luai" and "-a" or "analyze"
    check(program .. " preserves application arguments", function()
        with_analysis(function(captured)
            local expected = {"--format=json", "--color", "always", "", "--out=last"}
            local args = {action, "entry.lua", "--"}
            for _, value in ipairs(expected) do args[#args + 1] = value end
            local code, out, err = invoke(program, args)
            assert(code == 0, err)
            local options = assert(captured())
            assert(#options.run_args == #expected, "application argument count changed")
            for index, value in ipairs(expected) do
                assert(options.run_args[index] == value, "application argument changed at " .. index)
            end
            assert(not out:find('"schema_version"', 1, true), "application flags changed the output format")
        end)
    end)
    check(program .. " accepts explicit option-like values", function()
        with_analysis(function(captured)
            local code, _, err = invoke(program, {action, "entry.lua", "--include=--dir"})
            assert(code == 0, err)
            assert(captured().include[1] == "--dir", "explicit value was interpreted as an option")
        end)
    end)
    check(program .. " rejects conflicting discovery modes", function()
        with_analysis(function(captured)
            local code = invoke(program, {action, "entry.lua", "--no-depscan", "-d", "runtime"})
            assert(code == 1 and not captured(), "conflicting modes reached the operation")
        end)
    end)
    check(program .. " rejects conflicting scalar values", function()
        with_analysis(function(captured)
            local code = invoke(program, {action, "entry.lua", "--max-deps=2", "--max-deps=3"})
            assert(code == 1 and not captured(), "conflicting scalar values reached the operation")
        end)
    end)
end

check("display errors ignore application JSON flags", function()
    local code, out, err = invoke("luainstaller", {
        "analyze", "entry.lua", "--color=purple", "--", "--format=json",
    })
    assert(code == 1 and out == "" and err ~= "", "application argument selected JSON for a CLI error")
end)

check("display conflicts fail before operations", function()
    with_analysis(function(captured)
        local code = invoke("luainstaller", {
            "analyze", "entry.lua", "--color=always", "--no-color",
        })
        assert(code == 1 and not captured(), "conflicting display options reached the operation")
    end)
end)

check("command help needs no entry", function()
    for _, command in ipairs({"analyze", "trace", "build", "logs", "version"}) do
        local code, out, err = invoke("luainstaller", {command, "--help"})
        assert(code == 0 and out:find(command, 1, true), command .. " help failed: " .. err)
    end
end)

check("unknown help topic fails", function()
    local code = invoke("luainstaller", {"help", "not-a-command"})
    assert(code == 1, "unknown help topic was accepted")
end)

check("modern fields preserve complete paths", function()
    with_analysis(function()
        local path = string.rep("long-directory/", 20) .. "entry.lua"
        local code, out, err = invoke("luainstaller", {"analyze", path})
        assert(code == 0, err)
        assert(out:find(path, 1, true), "entry path was truncated")
    end)
end)

check("terminal text escapes untrusted controls", function()
    local original = logger.queryLogs
    logger.queryLogs = function()
        return {ok = true, status = "primary", logs = {{timestamp = "date", level = "info",
            source = "source", action = "action", message = "before\27[2Jafter", details = {}}}}
    end
    local called, code, out = pcall(invoke, "luainstaller", {"logs", "--no-color"})
    logger.queryLogs = original
    assert(called and code == 0, out)
    assert(not out:find("\27", 1, true), "log message emitted a terminal control sequence")
    assert(out:find("\\x1B[2J", 1, true), "escaped diagnostic is missing")
end)

check("JSON retains finite number precision", function()
    for _, number in ipairs({1.2345678901234567, 9007199254740991, 0.10000000000000002}) do
        assert(tonumber(present.encodeJson(number)) == number, "number changed during JSON encoding")
    end
end)

check("JSON escapes malformed UTF-8 bytes", function()
    assert(present.encodeJson(string.char(255)) == '"\\u00ff"', "invalid byte remained in JSON")
    assert(present.encodeJson("中文") == '"中文"', "valid UTF-8 was changed")
end)

check("JSON log recovery warnings stay structured", function()
    local original = logger.queryLogs
    logger.queryLogs = function() return {ok = true, status = "backup", logs = {}} end
    local called, code, out, err = pcall(invoke, "luainstaller", {"logs", "--format=json"})
    logger.queryLogs = original
    assert(called and code == 0, out)
    assert(err == "", "JSON recovery emitted a text warning")
    assert(out:find('"LogRecoveryWarning"', 1, true), "JSON recovery warning is missing")
end)

check("runtime discovery receives literal arguments", function()
    local fs = require("luainstaller.fs")
    local path = require("luainstaller.path")
    local process = require("luainstaller.process")
    local root = assert(fs.makePrivateDirectory("cli-literal-arguments"))
    local entry = path.join(root, "main.lua")
    assert(fs.writeFile(entry, [[
local expected = {"--format=json", "--color", "always", "", "--out=last"}
for index, value in ipairs(expected) do assert(arg[index] == value, "argument changed") end
require("dependency")
]]))
    assert(fs.writeFile(path.join(root, "dependency.lua"), "return true\n"))
    local called, failure = pcall(function()
        for _, program in ipairs({"luai", "luainstaller"}) do
            local args = {"bin/" .. program .. ".lua", program == "luai" and "-a" or "analyze",
                entry, "-d", "runtime", "--", "--format=json", "--color", "always", "", "--out=last"}
            local ok, output = process.outputCommand(harness.lua_command(), args)
            assert(ok, output)
            assert(output:find("dependency.lua", 1, true), "runtime dependency was not discovered")
            assert(not output:find('"schema_version"', 1, true), "application option selected JSON")
        end
    end)
    assert(fs.removeTree(root))
    assert(called, failure)
end)

if #failures > 0 then error(table.concat(failures, "\n"), 0) end
print("CLI argument and output boundaries ok")
