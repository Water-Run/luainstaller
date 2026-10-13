--[[
MoonScript keeps interruption identity across preparation and cleanup boundaries.

Author:
    WaterRun
File:
    moon_interruption.lua
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
local bundler = require("luainstaller.bundler")
local root = assert(fs.makePrivateDirectory("moon-interruption"))
local entry = path.join(root, "main.moon")
assert(fs.writeFile(entry, 'print "moon interruption"\n'))
local prepare, remap, output_command, make_private = moon.prepare, moon.remap,
    process.outputCommand, fs.makePrivateDirectory
local bundle_onedir = bundler.bundleOnedir
local workspaces = {}
fs.makePrivateDirectory = function(prefix, ...)
    local directory, error_value = make_private(prefix, ...)
    if prefix == "moon-work" and directory then workspaces[#workspaces + 1] = directory end
    return directory, error_value
end
local called, failure = pcall(function()
    for _, structured in ipairs({false, true}) do
        for _, fault in ipairs({"prepare", "compile", "verify", "remap", "cleanup"}) do
            local function interrupt()
                error(structured and {type="InterruptedError", message="injected interruption"}
                    or "interrupted!", 0)
            end
            moon.prepare = function(options)
                if fault == "prepare" then interrupt() end
                local context, error_value = prepare(options)
                if context and fault == "verify" then context.verify = interrupt end
                if context and fault == "cleanup" then context.cleanup = interrupt end
                return context, error_value
            end
            moon.remap = fault == "remap" and interrupt or remap
            process.outputCommand = function(executable, arguments, environment, options)
                if fault == "compile" and ((arguments and arguments[1] == "-p")
                    or (environment and environment.LUAI_MOON_INPUT)) then interrupt() end
                return output_command(executable, arguments, environment, options)
            end
            local returned, response = pcall(api.analyze, {entry=entry})
            moon.prepare, moon.remap, process.outputCommand = prepare, remap, output_command
            assert(returned and not response.ok and response.error.type == "InterruptedError",
                fault .. " changed interruption identity: " .. tostring(response and response.error and response.error.type))
            for _, workspace in ipairs(workspaces) do
                if fs.pathType(workspace) == "directory" then
                    assert(fault == "cleanup" and response.error.cleanup_path == workspace,
                        fault .. " left an unreported workspace")
                    assert(fs.removeTree(workspace))
                end
            end
        end
    end
    for _, fault in ipairs({"cleanup", "failed-result-remap"}) do
        local built
        local function interrupt() error("interrupted!", 0) end
        moon.prepare = function(options)
            local context, error_value = prepare(options)
            if context and fault == "cleanup" then context.cleanup = interrupt end
            return context, error_value
        end
        bundler.bundleOnedir = function(options)
            local response = bundle_onedir(options)
            assert(response.ok, response.error and response.error.message)
            built = response
            if fault == "failed-result-remap" then
                return {ok=false, error={type="FilesystemError", message="injected post-publication error", committed=true}}
            end
            return response
        end
        moon.remap = fault == "failed-result-remap" and interrupt or remap
        local response = api.bundle({entry=entry, out=path.join(root, "committed-" .. fault)})
        moon.prepare, moon.remap, bundler.bundleOnedir = prepare, remap, bundle_onedir
        assert(not response.ok and response.error.type == "InterruptedError" and response.error.committed,
            fault .. " lost the already committed output state")
        local ran, output = process.outputCommand(built.executable, {}, {LUA_PATH="", LUA_CPATH=""})
        assert(ran and output:find("moon interruption", 1, true), output)
        for _, workspace in ipairs(workspaces) do
            if fs.pathType(workspace) == "directory" then
                assert(response.error.cleanup_path == workspace, "committed failure left an unreported workspace")
                assert(fs.removeTree(workspace))
            end
        end
    end
    if package.config:sub(1, 1) == "/" then
        local compiler_bin = path.join(root, "compiler-bin")
        local marker = path.join(root, "compiler-ready")
        local diagnostic = path.join(root, "interrupted.log")
        local launcher = path.join(root, "exec-clean-signals")
        assert(fs.makeDirectory(compiler_bin))
        local wrapper = path.join(compiler_bin, "moonc")
        assert(fs.writeFile(wrapper, [[#!/bin/sh
set -eu
printf '%s\n%s\n' "$$" "$2" > "$LUAI_MOON_SIGNAL_READY"
trap 'exit 130' INT TERM HUP
while :; do sleep 1; done
]]))
        assert(fs.setExecutable(wrapper))
        local compiled, compiler_output = process.outputCommand("cc", {
            "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
            "test/fixtures/exec_clean_signals.c", "-o", launcher,
        })
        assert(compiled, compiler_output)
        local lua = harness.lua_command()
        if fs.pathType(lua) ~= "file" then lua = assert(process.firstLine("command -v " .. process.shellQuote(lua))) end
        local old_abi = _VERSION == "Lua 5.1" or _VERSION == "Lua 5.2"
        local attempts = old_abi and 4800 or 1200
        local script = table.concat({
            "set -eu",
            "PATH=" .. process.shellQuote(compiler_bin .. ":" .. (os.getenv("PATH") or "")),
            "LUAI_MOON_SIGNAL_READY=" .. process.shellQuote(marker),
            "LUAI_CMD_TIMEOUT=30",
            "LUAINSTALLER_CLI_NAME=luainstaller",
            "export PATH LUAI_MOON_SIGNAL_READY LUAI_CMD_TIMEOUT LUAINSTALLER_CLI_NAME",
            process.shellQuote(launcher) .. " " .. process.shellQuote(lua)
                .. " src/cli.lua build " .. process.shellQuote(entry) .. " --dir -o "
                .. process.shellQuote(path.join(root, "output")) .. " >" .. process.shellQuote(diagnostic) .. " 2>&1 &",
            "builder=$!",
            "ready=0; attempt=0",
            "while test \"$attempt\" -lt " .. attempts .. "; do",
            "  if test -f " .. process.shellQuote(marker) .. "; then ready=1; break; fi",
            "  if ! kill -0 \"$builder\" 2>/dev/null; then break; fi",
            "  sleep 0.025; attempt=$((attempt + 1))",
            "done",
            "if test \"$ready\" -ne 1; then kill -KILL \"-$builder\" 2>/dev/null || true; exit 1; fi",
            "kill -INT \"-$builder\"",
            "set +e; wait \"$builder\"; status=$?; set -e",
            "printf 'status=%s\\n' \"$status\"",
        }, "\n")
        local ran, output = process.output(script, {timeout_seconds=old_abi and 600 or 120})
        local log = fs.readRegularFile(diagnostic) or ""
        assert(ran and output:match("status=(%d+)") == "130", tostring(output) .. "\n" .. log)
        local compiler_pid, snapshot = assert(fs.readRegularFile(marker)):match("^(%d+)\n([^\n]+)\n$")
        assert(compiler_pid and snapshot, "compiler readiness omitted its process and snapshot")
        local stopped, stop_output = process.outputCommand("sh", {"-c", [[
attempt=0
while kill -0 "$1" 2>/dev/null && test "$attempt" -lt 100; do
    sleep 0.05
    attempt=$((attempt + 1))
done
if kill -0 "$1" 2>/dev/null; then exit 1; fi
]], "sh", compiler_pid})
        assert(stopped, "SIGINT left moonc running: " .. tostring(stop_output))
        assert(fs.pathType(path.dirname(path.dirname(snapshot))) == "missing", "SIGINT left the MoonScript workspace")
        assert(fs.pathType(path.join(root, "output")) == "missing", "SIGINT published an output")
        assert(not log:find("stack traceback", 1, true), log)
        local retried, retry_output = process.outputCommand(lua, {"src/cli.lua", "analyze", entry},
            {LUAINSTALLER_CLI_NAME="luainstaller"}, {timeout_seconds=old_abi and 600 or 120})
        assert(retried, retry_output)
    end
end)
moon.prepare, moon.remap, process.outputCommand, fs.makePrivateDirectory =
    prepare, remap, output_command, make_private
bundler.bundleOnedir = bundle_onedir
for _, workspace in ipairs(workspaces) do
    if fs.pathType(workspace) == "directory" then assert(fs.removeTree(workspace)) end
end
assert(fs.removeTree(root))
assert(called, failure)
print("MoonScript interruption boundaries ok")
