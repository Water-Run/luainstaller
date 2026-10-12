--[[
Command deadlines and output budgets remain effective without GNU timeout.

Author:
    WaterRun
File:
    process_bounds.lua
Date:
    2026-10-12
Updated:
    2026-10-12
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local process = require("luainstaller.process")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local api = require("luainstaller")
local root = assert(fs.makePrivateDirectory("process-bounds"))
local driver = path.join(root, "driver.lua")
assert(fs.writeFile(driver, [[
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local process = require("luainstaller.process")
local ok, output, status = process.outputCommand("sh", {"-c", "sleep 3; echo escaped-deadline"},
    {}, {timeout_seconds=0.15})
assert(not ok, "requested deadline was silently ignored")
assert(status and status.reason == "timeout", tostring(output))
print("deadline enforced without GNU timeout")
]]))
local called, failure = xpcall(function()
    if package.config:sub(1, 1) == "/" then
        local timeout = path.join(root, "timeout")
        assert(fs.writeFile(timeout, "#!/bin/sh\nexit 127\n"))
        assert(fs.setExecutable(timeout))
        local checked, output = process.outputCommand(harness.lua_command(), {driver},
            {PATH=root .. ":" .. (os.getenv("PATH") or "")}, {timeout_seconds=20})
        assert(checked, output)
    end
    local limited, output, status = process.outputCommand(harness.lua_command(), {
        "-e", "io.write(string.rep('x', 65536)); io.flush()",
    }, {}, {timeout_seconds=10, max_output_bytes=4096})
    assert(not limited and #output <= 4096 + 256, "output budget did not stop the child")
    assert(status and status.reason == "output-limit", "output limit has no structured status")
    local failed, _, exit_status = process.outputCommand(harness.lua_command(), {"-e", "os.exit(37)"})
    assert(not failed and exit_status and exit_status.code == 37, "exit status was not preserved")
    local echo = path.join(root, "echo.lua")
    assert(fs.writeFile(echo, "io.write(arg[1])\n"))
    local echoed, argument = process.outputCommand(harness.lua_command(), {
        echo, "quotes'\"; & $() | % end",
    }, {}, {timeout_seconds=10})
    assert(echoed and argument == "quotes'\"; & $() | % end", argument)
    local entry = path.join(root, "runtime.lua")
    assert(fs.writeFile(entry, "while true do end\n"))
    local traced = api.analyze({entry=entry, discovery_mode="runtime", runtime_timeout=0.15,
        lua=harness.lua_command()})
    assert(not traced.ok and traced.error.type == "RuntimeTimeoutError"
        and traced.error.timeout_seconds == 0.15
        and traced.error.command_status.reason == "timeout", "runtime deadline was not diagnosed")
    assert(fs.writeFile(entry, "require('snapshot')\n"))
    assert(fs.writeFile(path.join(root, "snapshot.lua"), "return '" .. string.rep("x", 200) .. "'\n"))
    traced = api.analyze({entry=entry, discovery_mode="runtime", max_source_bytes=64,
        lua=harness.lua_command()})
    assert(not traced.ok and traced.error.type == "ResourceLimitExceededError"
        and traced.error.resource == "source-bytes", "runtime snapshot budget was ignored")
end, function(err) return err end)
assert(fs.removeTree(root))
assert(called, failure)
print("bounded process execution ok")
