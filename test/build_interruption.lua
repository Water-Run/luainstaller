--[[
Crash-recovery integration test for interrupted native builds.

Author:
    WaterRun
File:
    build_interruption.lua
Date:
    2026-07-18
Updated:
    2026-08-16
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

if package.config:sub(1, 1) ~= "/" then
    print("build interruption test skipped on Windows host")
    return
end

local fs = require("luainstaller.fs")
local hash = require("luainstaller.hash")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local root = assert(fs.makePrivateDirectory("build-interruption"))
local entry = path.join(root, "main.lua")
local out = path.join(root, "out")
local wrapper = path.join(root, "slow-cc")
local launcher = path.join(root, "exec-clean-signals")
local configured_lua = harness.lua_command()
local lua = fs.pathType(configured_lua) == "file" and configured_lua
    or assert(process.firstLine("command -v " .. process.shellQuote(configured_lua)))

local function cleanup()
    if fs.pathType(root) == "directory" then fs.removeTree(root) end
end

local called, failure = xpcall(function()
    assert(fs.writeFile(entry, [[print("interruption retry ok")
]]))
    assert(fs.writeFile(wrapper, [[#!/bin/sh
set -eu
for value in "$@"; do
    case "$value" in
        */launcher.c)
            printf '%s\n' "$$" > "$LUAI_INTERRUPT_READY"
            trap 'exit 130' INT TERM HUP
            while :; do sleep 1; done
            ;;
    esac
done
exec "$LUAI_REAL_CC" "$@"
]]))
    assert(fs.setExecutable(wrapper))
    local compiled, compile_output = process.outputCommand("cc", {
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
        "test/fixtures/exec_clean_signals.c", "-o", launcher,
    })
    assert(compiled, compile_output)

    local real_cc = assert(process.firstLine("command -v cc"))
    local function stagingCount()
        local count = 0
        for _, item in ipairs(assert(fs.listTree(root))) do
            if not item.path:find("/", 1, true)
                and item.path:find(".luai-staging-", 1, true) == 1 then
                count = count + 1
            end
        end
        return count
    end
    local function interruptBuild(target, signal_name, label, timeout_seconds)
        local marker = path.join(root, "compiler-ready-" .. label)
        local diagnostic_path = path.join(root, "interrupted-" .. label .. ".log")
        local script = table.concat({
            "set -eu",
            "CC=" .. harness.shell_quote(wrapper),
            "LUAI_CC=" .. harness.shell_quote(wrapper),
            "LUAI_REAL_CC=" .. harness.shell_quote(real_cc),
            "LUAI_INTERRUPT_READY=" .. harness.shell_quote(marker),
            "LUAI_CMD_TIMEOUT=" .. tostring(timeout_seconds),
            "LUAINSTALLER_CLI_NAME=luainstaller",
            "export CC LUAI_CC LUAI_REAL_CC LUAI_INTERRUPT_READY LUAI_CMD_TIMEOUT LUAINSTALLER_CLI_NAME",
            harness.shell_quote(launcher) .. " " .. harness.shell_quote(lua)
                .. " src/cli.lua build " .. harness.shell_quote(entry)
                .. " --dir -o " .. harness.shell_quote(target)
                .. " >" .. harness.shell_quote(diagnostic_path) .. " 2>&1 &",
            "build=$!",
            "ready_seen=0",
            "attempt=0",
            "while test \"$attempt\" -lt 400; do",
            "  if test -f " .. harness.shell_quote(marker) .. "; then ready_seen=1; break; fi",
            "  if ! kill -0 \"$build\" 2>/dev/null; then break; fi",
            "  sleep 0.025",
            "  attempt=$((attempt + 1))",
            "done",
            "test \"$ready_seen\" -eq 1",
            -- POSIX kill accepts a negative operand after an explicit signal.
            -- dash's builtin does not accept the otherwise common `--`
            -- separator and misparses it as an empty process-group id.
            "kill -" .. signal_name .. " \"-$build\"",
            "set +e",
            "wait \"$build\"",
            "status=$?",
            "set -e",
            "printf 'status=%s\\n' \"$status\"",
        }, "\n")
        local interrupted_ok, interrupted_output = process.output(script)
        local diagnostic = fs.readRegularFile(diagnostic_path) or ""
        assert(interrupted_ok, tostring(interrupted_output) .. "\nbuild log:\n" .. diagnostic)
        local compiler_pid = tonumber((fs.readRegularFile(marker) or ""):match("^(%d+)"))
        assert(compiler_pid, "compiler marker did not contain a PID")
        return tonumber(interrupted_output:match("status=(%d+)")), diagnostic, compiler_pid
    end
    local function waitForProcessExit(pid, maximum_seconds)
        local wait_script = table.concat({
            'pid="$1"',
            'limit="$2"',
            "elapsed=0",
            'while kill -0 "$pid" 2>/dev/null && test "$elapsed" -lt "$limit"; do',
            "  sleep 1",
            "  elapsed=$((elapsed + 1))",
            "done",
            'if kill -0 "$pid" 2>/dev/null; then',
            '  kill -KILL "$pid" 2>/dev/null || true',
            "  exit 1",
            "fi",
        }, "\n")
        local exited, output = process.outputCommand("sh", {
            "-c", wait_script, "sh", tostring(pid), tostring(maximum_seconds),
        })
        return exited, output
    end
    local function retryBuild(target)
        local retry_ok, retry_output = process.outputCommand(lua, {
            "src/cli.lua", "build", entry, "--dir", "-o", target,
        }, {
            LUAINSTALLER_CLI_NAME = "luainstaller",
            CC = real_cc,
            LUAI_CC = real_cc,
        })
        assert(retry_ok, retry_output)
        local lock_path = path.join(root, ".luai-lock-" .. hash.sha256(target))
        assert(fs.pathType(lock_path) == "missing", "retry left an output lock")
        assert(stagingCount() == 0, "retry left staging state")
    end

    local interrupt_status, interrupt_diagnostic, interrupt_compiler =
        interruptBuild(out, "INT", "sigint", 30)
    assert(interrupt_status == 130, "SIGINT status: " .. tostring(interrupt_status)
        .. "\nbuild log:\n" .. interrupt_diagnostic)
    local interrupt_stopped, interrupt_stop_output = waitForProcessExit(interrupt_compiler, 5)
    assert(interrupt_stopped,
        "SIGINT left the compiler running: " .. tostring(interrupt_stop_output))
    assert(not interrupt_diagnostic:find("stack traceback", 1, true), interrupt_diagnostic)
    assert(fs.pathType(path.join(root, ".luai-lock-" .. hash.sha256(out))) == "missing",
        "SIGINT left an output lock")
    assert(stagingCount() == 0, "SIGINT left staging state")
    retryBuild(out)

    local killed_out = path.join(root, "out-killed")
    local killed_status, _, killed_compiler =
        interruptBuild(killed_out, "KILL", "sigkill", 3)
    assert(killed_status == 137, "SIGKILL status: " .. tostring(killed_status))
    local killed_lock = path.join(root, ".luai-lock-" .. hash.sha256(killed_out))
    assert(fs.pathType(killed_lock) == "directory",
        "SIGKILL did not leave a dead-owner recovery fixture")
    assert(stagingCount() == 1, "SIGKILL staging fixture count: " .. stagingCount())
    local killed_stopped, killed_stop_output = waitForProcessExit(killed_compiler, 10)
    assert(killed_stopped,
        "SIGKILL compiler exceeded its configured timeout: " .. tostring(killed_stop_output))
    retryBuild(killed_out)

    local empty_path = path.join(root, "empty-path")
    assert(fs.makeDirectory(empty_path))
    local ran, output = process.outputCommand(path.join(killed_out, "out-killed"), {}, {
        PATH = empty_path,
        LUA_PATH = "",
        LUA_CPATH = "",
        LUA_INIT = "",
    })
    assert(ran and output:find("interruption retry ok", 1, true), output)
end, function(err)
    return err
end)

cleanup()
assert(called, failure)
print("build interruption recovery ok: relayed SIGINT, bounded SIGKILL, clean retry")
