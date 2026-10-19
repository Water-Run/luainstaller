--[[
Focused smoke tests for the split luai / luainstaller CLI contract.

Author:
    WaterRun
File:
    cli_split_smoke.lua
Date:
    2026-06-24
Updated:
    2026-10-13
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local cli = require("luainstaller.cli")

local function assert_contains(haystack, needle)
    if not tostring(haystack):find(needle, 1, true) then
        error(string.format("expected output to contain %q\noutput:\n%s", needle, tostring(haystack)), 2)
    end
end

local function assert_not_contains(haystack, needle)
    if tostring(haystack):find(needle, 1, true) then
        error(string.format("expected output not to contain %q\noutput:\n%s", needle, tostring(haystack)), 2)
    end
end

local function run_cli(program_name, args, context)
    local stdout = {}
    local stderr = {}
    local old_io = io
    local fake_io = {}
    for k, v in pairs(old_io) do
        fake_io[k] = v
    end
    fake_io.write = function(...)
        for i = 1, select("#", ...) do
            stdout[#stdout + 1] = tostring(select(i, ...))
        end
    end
    fake_io.stderr = {
        write = function(_, ...)
            for i = 1, select("#", ...) do
                stderr[#stderr + 1] = tostring(select(i, ...))
            end
        end,
    }
    _G.io = fake_io
    local ok, code = pcall(function()
        context = context or {}
        context.program_name = program_name
        return cli.main(args, context)
    end)
    _G.io = old_io
    if not ok then
        error(code, 2)
    end
    return code, table.concat(stdout), table.concat(stderr)
end

local code, out, err = run_cli("luai", { "-h" })
assert(code == 0)
assert_contains(out, "Usage: luai -h")
assert_contains(out, "luai -a <entry.lua>")
assert_not_contains(out, "luainstaller analyze")
assert(err == "")

local logger = require("luainstaller.logger")
local original_get_logs = logger.getLogs
local original_query_logs = logger.queryLogs
local log_options
logger.queryLogs = function(opts)
    log_options = opts
    return { ok = true, status = "primary", logs = {
        {
            timestamp = "2026-10-12T00:00:00Z",
            level = "error",
            source = "fixture",
            action = "build",
            message = "log command fixture",
        },
    } }
end
code, out, err = run_cli("luai", {
    "-l", "--level", "error", "--limit", "20", "--asc",
})
logger.queryLogs = original_query_logs
logger.getLogs = original_get_logs
assert(code == 0, err)
assert(log_options.level == "error" and log_options.limit == 20
    and log_options.descending == false)
assert_contains(out, "logs: 1\n")
assert_contains(out, "2026-10-12T00:00:00Z\terror\tfixture:build\tlog command fixture\n")
assert_not_contains(out, "\27[")
assert(err == "")

logger.queryLogs = function() return { ok = true, status = "empty", logs = {} } end
code, out, err = run_cli("luai", { "-l" })
logger.queryLogs = original_query_logs
logger.getLogs = original_get_logs
assert(code == 0 and out == "no logs\n" and err == "")
for _, arguments in ipairs({
    { "-l", "--limit", "1e999" },
    { "-l", "--limit", "--asc" },
    { "-l", "--level", "invalid" },
    { "-l", "unexpected.lua" },
}) do
    code, out, err = run_cli("luai", arguments)
    assert(code == 1 and out == "" and err ~= "")
end

code, out, err = run_cli("luainstaller", { "help" }, { color = false })
assert(code == 0)
assert_contains(out, "Usage: luainstaller <command>")
assert_contains(out, "luainstaller analyze <entry.lua>")
assert_contains(out, "--discovery-mode")
assert_not_contains(out, "luai -a <entry.lua>")
assert_not_contains(out, "--require-engine")
assert_not_contains(out, "engines")
assert(err == "")

code, out, err = run_cli("luai", { "build", "test/single_file/01_hello_luainstaller.lua" })
assert(code == 1)
assert(out == "")
assert_contains(err, "error: unknown luai command: build")

code, out, err = run_cli("luainstaller", { "-b", "test/single_file/01_hello_luainstaller.lua" }, { color = false })
assert(code == 1)
assert(out == "")
assert_contains(err, "error: unknown luainstaller command: -b")

code, out, err = run_cli("luainstaller", { "engines" }, { color = false })
assert(code == 1)
assert(out == "")
assert_contains(err, "error: unknown luainstaller command: engines")

local api = require("luainstaller")
local captured_moon_options
local original_analyze = api.analyze
api.analyze = function(options)
    captured_moon_options = options
    return {ok=true, entry=options.entry, dependencies={scripts={}, libraries={}}, trace={}}
end
code, out, err = run_cli("luai", {"-a", "example.moon", "-M"})
assert(code == 0 and captured_moon_options.moon_detect == false, err)
code, out, err = run_cli("luainstaller", {"analyze", "example.moon", "--no-moon-detect"}, {color=false})
assert(code == 0 and captured_moon_options.moon_detect == false, err)
api.analyze = original_analyze
local captured_file_options
local original_mode_bundle = api.bundle
api.bundle = function(options)
    captured_file_options = options
    return {ok=true, out="fixture", executable="fixture", mode="onefile", onefile_mode="no-extract"}
end
code, out, err = run_cli("luai", {"-b", "example.lua", "--file-mode", "no-extract"})
assert(code == 0 and captured_file_options.mode == "onefile"
    and captured_file_options.onefile_mode == "no-extract", err)
code, out, err = run_cli("luainstaller", {"build", "example.lua", "--file-mode", "extract"}, {color=false})
assert(code == 0 and captured_file_options.onefile_mode == "extract", err)
api.bundle = original_mode_bundle
code, out, err = run_cli("luai", {"-b", "example.lua", "--file-mode", "--dir"})
assert(code == 1 and err:find("requires a value", 1, true))
local original_bundle = api.bundle
api.bundle = function()
    return {
        ok = false,
        error = {
            type = "CompilationFailedError",
            message = "diagnostic fixture",
            command = "cc fixture.c",
            output = "compiler diagnostic fixture\n",
        },
    }
end
code, out, err = run_cli("luainstaller", {
    "build", "test/single_file/01_hello_luainstaller.lua",
}, { color = false })
assert(code == 1)
assert(out == "")
assert_not_contains(err, "cc fixture.c")
code, out, err = run_cli("luainstaller", {
    "build", "test/single_file/01_hello_luainstaller.lua", "--verbose",
}, { color = false })
api.bundle = original_bundle
assert(code == 1)
assert(out == "")
assert_contains(err, "command: cc fixture.c")
assert_contains(err, "output: compiler diagnostic fixture")

code, out, err = run_cli("luai", {
    "-a",
    "test/runtime_bundle/main.lua",
    "--max-deps",
    "250",
})
assert(code == 0)
assert_contains(out, "ok")
assert_contains(out, "scripts:")
assert_not_contains(out, "\27[")
assert(err == "")

code, out, err = run_cli("luai", {
    "-a",
    "test/runtime_bundle/main.lua",
    "-o",
    "--dir",
})
assert(code == 1)
assert(out == "")
assert_contains(err, "-o requires a value")
assert_contains(err, "--dir")

code, out, err = run_cli("luai", {
    "-b",
    "test/runtime_bundle/main.lua",
    "--max-deps",
    "--dir",
})
assert(code == 1)
assert(out == "")
assert_contains(err, "--max-deps requires a value")

code, out, err = run_cli("luainstaller", {
    "analyze",
    "test/runtime_bundle/main.lua",
    "--max-deps",
    "250",
}, { color = true, animations = false })
assert(code == 0, "modern analysis failed: " .. err)
assert_contains(out, "\27[")
assert_contains(out, "Analysis complete")
assert_contains(out, "Lua scripts")
assert(err == "")

print("cli split smoke ok")
