--[[
Onefile process-lifecycle integration tests.

Author:
    WaterRun
File:
    onefile_lifecycle.lua
Date:
    2026-07-18
Updated:
    2026-07-18
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

if package.config:sub(1, 1) == "\\" then
    local root = assert(fs.makePrivateDirectory("onefile-lifecycle-windows"))
    local entry = path.join(root, "main.lua")
    local artifact = path.join(root, "lifecycle-onefile.exe")
    local ready = path.join(root, "inner-ready.txt")
    local script = path.join(root, "lifecycle.ps1")
    local called, failure = xpcall(function()
        assert(fs.writeFile(entry, [[
if arg[1] == "exit23" then os.exit(23) end
local ready_file = assert(arg[1], "ready-file argument is required")
local handle = assert(io.open(ready_file, "wb"))
assert(handle:write("ready\n"))
assert(handle:flush())
assert(handle:close())
local accumulator = 0
while true do
    for index = 1, 100000 do accumulator = accumulator + index end
    if accumulator > 1000000000000 then accumulator = 0 end
end
]]))
        local built = require("luainstaller").bundle({
            entry = entry,
            out = artifact,
            mode = "onefile",
        })
        assert(built.ok, built.error and table.concat({
            tostring(built.error.message),
            tostring(built.error.output or built.error.cause or ""),
        }, "\n"))
        assert(fs.writeFile(script, [[
param([string]$Artifact,[string]$ReadyFile)
$ErrorActionPreference='Stop'
if(Test-Path -LiteralPath $ReadyFile){Remove-Item -LiteralPath $ReadyFile -Force}
$QuotedReady='"'+$ReadyFile+'"'
$Outer=Start-Process -FilePath $Artifact -ArgumentList @($QuotedReady) -PassThru
$InnerId=0
try {
    $ReadySeen=$false
    for($Attempt=0;$Attempt -lt 400;$Attempt++){
        if(Test-Path -LiteralPath $ReadyFile -PathType Leaf){$ReadySeen=$true;break}
        if($Outer.HasExited){break}
        Start-Sleep -Milliseconds 25
    }
    if(-not $ReadySeen){throw 'inner launcher did not become ready'}
    $Children=@(Get-WmiObject Win32_Process -Filter ('ParentProcessId='+$Outer.Id))
    if($Children.Count -ne 1){throw ('expected one inner process, got '+$Children.Count)}
    $InnerId=[int]$Children[0].ProcessId
    Stop-Process -Id $Outer.Id -Force
    for($Attempt=0;$Attempt -lt 400;$Attempt++){
        $OuterAlive=$null -ne (Get-Process -Id $Outer.Id -ErrorAction SilentlyContinue)
        $InnerAlive=$null -ne (Get-Process -Id $InnerId -ErrorAction SilentlyContinue)
        if(-not $OuterAlive -and -not $InnerAlive){break}
        Start-Sleep -Milliseconds 25
    }
    $OuterAlive=$null -ne (Get-Process -Id $Outer.Id -ErrorAction SilentlyContinue)
    $InnerAlive=$null -ne (Get-Process -Id $InnerId -ErrorAction SilentlyContinue)
    [Console]::WriteLine('outer={0} inner={1} outer_alive={2} inner_alive={3}',
        $Outer.Id,$InnerId,[int]$OuterAlive,[int]$InnerAlive)
} finally {
    Stop-Process -Id $Outer.Id -Force -ErrorAction SilentlyContinue
    if($InnerId -gt 0){Stop-Process -Id $InnerId -Force -ErrorAction SilentlyContinue}
}
$Exit=Start-Process -FilePath $Artifact -ArgumentList @('exit23') -Wait -PassThru
[Console]::WriteLine('exit={0}',$Exit.ExitCode)
]]))
        local powershell = assert(process.windowsPowerShellPath())
        local ok, output = process.outputCommand(powershell, {
            "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-File", script, artifact, ready,
        })
        assert(ok, output)
        local outer, inner, outer_alive, inner_alive = output:match(
            "outer=(%d+) inner=(%d+) outer_alive=(%d+) inner_alive=(%d+)"
        )
        assert(outer and inner, output)
        assert(outer ~= inner, "Windows onefile unexpectedly reused the outer PID")
        assert(outer_alive == "0" and inner_alive == "0",
            "terminating the Windows outer process left its child alive: " .. output)
        assert(tonumber(output:match("exit=(%d+)")) == 23,
            "Windows onefile did not preserve exit status 23: " .. output)
    end, function(err)
        return err
    end)
    if fs.pathType(root) == "directory" then fs.removeTree(root) end
    assert(called, failure)
    print("onefile lifecycle ok: Windows Job Object containment, exit 23")
    return
end

local root = assert(fs.makePrivateDirectory("onefile-lifecycle"))
local entry = path.join(root, "main.lua")
local artifact = path.join(root, "lifecycle-onefile")
local signal_launcher = path.join(root, "exec-clean-signals")

local function cleanup()
    if fs.pathType(root) == "directory" then fs.removeTree(root) end
end

local called, failure = xpcall(function()
    assert(fs.writeFile(entry, [=[
if arg[1] == "exit23" then os.exit(23) end
local pid_file = assert(arg[1], "pid file argument is required")
local pipe = assert(io.popen([[printf '%s' "$PPID"]], "r"))
local pid = assert(pipe:read("*l"))
assert(pipe:close())
local handle = assert(io.open(pid_file, "wb"))
assert(handle:write(pid, "\n"))
assert(handle:flush())
assert(handle:close())
local accumulator = 0
while true do
    for index = 1, 100000 do accumulator = accumulator + index end
    if accumulator > 1000000000000 then accumulator = 0 end
end
]=]))

    local compiled, compile_output = process.outputCommand("cc", {
        "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic",
        "test/fixtures/exec_clean_signals.c", "-o", signal_launcher,
    })
    assert(compiled, compile_output)

    local built = require("luainstaller").bundle({
        entry = entry,
        out = artifact,
        mode = "onefile",
    })
    assert(built.ok, built.error and table.concat({
        tostring(built.error.message),
        tostring(built.error.output or built.error.cause or ""),
    }, "\n"))

    local function signalRun(signal_name)
        local pid_file = path.join(root, "pid-" .. signal_name:lower())
        local script = table.concat({
            "set -eu",
            harness.shell_quote(signal_launcher) .. " " .. harness.shell_quote(artifact)
                .. " " .. harness.shell_quote(pid_file) .. " >/dev/null 2>&1 &",
            "outer=$!",
            "ready=0",
            "attempt=0",
            "while test \"$attempt\" -lt 200; do",
            "  if test -s " .. harness.shell_quote(pid_file) .. "; then ready=1; break; fi",
            "  if ! kill -0 \"$outer\" 2>/dev/null; then break; fi",
            "  sleep 0.025",
            "  attempt=$((attempt + 1))",
            "done",
            "test \"$ready\" -eq 1",
            "inner=$(sed -n '1p' " .. harness.shell_quote(pid_file) .. ")",
            "kill -" .. signal_name .. " \"$outer\"",
            "stopped=0",
            "attempt=0",
            "while test \"$attempt\" -lt 200; do",
            "  if ! kill -0 \"$outer\" 2>/dev/null; then stopped=1; break; fi",
            "  sleep 0.025",
            "  attempt=$((attempt + 1))",
            "done",
            "outer_alive=0",
            "if test \"$stopped\" -ne 1; then outer_alive=1; kill -KILL \"$outer\" 2>/dev/null || true; fi",
            "set +e",
            "wait \"$outer\" 2>/dev/null",
            "status=$?",
            "set -e",
            "inner_alive=0",
            "if kill -0 \"$inner\" 2>/dev/null; then",
            "  inner_alive=1",
            "  kill -KILL \"$inner\" 2>/dev/null || true",
            "fi",
            "printf 'outer=%s inner=%s status=%s outer_alive=%s inner_alive=%s\\n'"
                .. " \"$outer\" \"$inner\" \"$status\" \"$outer_alive\" \"$inner_alive\"",
        }, "\n")
        local ok, output = process.output(script)
        assert(ok, output)
        local outer, inner, status, outer_alive, inner_alive = output:match(
            "outer=(%d+) inner=(%d+) status=(%d+) outer_alive=(%d+) inner_alive=(%d+)"
        )
        assert(outer, output)
        return {
            outer = outer,
            inner = inner,
            status = tonumber(status),
            outer_alive = tonumber(outer_alive),
            inner_alive = tonumber(inner_alive),
        }
    end

    local term = signalRun("TERM")
    local interrupt = signalRun("INT")
    assert(term.outer == term.inner, "SIGTERM invocation retained a distinct inner PID")
    assert(interrupt.outer == interrupt.inner, "SIGINT invocation retained a distinct inner PID")
    assert(term.outer_alive == 0 and term.inner_alive == 0,
        "SIGTERM left the onefile application alive")
    assert(interrupt.outer_alive == 0 and interrupt.inner_alive == 0,
        "SIGINT left the onefile application alive")
    assert(term.status == 143, "SIGTERM status: " .. tostring(term.status))
    assert(interrupt.status == 130, "SIGINT status: " .. tostring(interrupt.status))

    local exit_ok, exit_output = process.output(
        "set +e\n" .. harness.shell_quote(artifact)
            .. " exit23 >/dev/null 2>&1\nstatus=$?\nprintf 'status=%s\\n' \"$status\""
    )
    assert(exit_ok, exit_output)
    assert(tonumber(exit_output:match("status=(%d+)")) == 23,
        "onefile did not preserve exit status 23: " .. tostring(exit_output))
end, function(err)
    return err
end)

cleanup()
assert(called, failure)
print("onefile lifecycle ok: PID, SIGTERM, SIGINT, exit 23")
