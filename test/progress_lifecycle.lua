--[[
Native progress follows its owner and releases terminal resources.

Author:
    WaterRun
File:
    progress_lifecycle.lua
Date:
    2026-10-19
Updated:
    2026-10-19
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local toolchain = require("luainstaller.toolchain")
local windows = package.config:sub(1, 1) == "\\"
local root = assert(fs.makePrivateDirectory("progress-lifecycle"))
local called, failure = pcall(function()
    local compiler, err = toolchain.resolveCompiler({})
    assert(compiler, err and err.error.message)
    local fixture = path.join(root, windows and "console-probe.exe" or "progress-owner")
    local source = windows and "test/fixtures/windows_console_probe.c" or "test/fixtures/progress_owner.c"
    local built, output = toolchain.compileStandalone(compiler, path.absolute(source), fixture, { work_dir = root })
    assert(built, output)
    local arguments
    if windows then
        local script = path.join(root, "console.lua")
        assert(fs.writeFile(script, harness.loader_prelude() .. [[
local host = require("luainstaller.windows_host")
local present = require("luainstaller.cli_present")
assert(host.call("pid"))
assert(present.streamIsTTY(1) and present.streamIsTTY(2), "native console not detected")
if not assert(present.consoleInfo(2)).capable then
    assert(not present.startRedraw("Checking"), "legacy console unexpectedly enabled VT progress")
    present.write("Console 测试\n")
    return
end
local stop, pause = assert(present.startRedraw("Checking"))
if arg[1] == "kill" then while true do end end
assert(host.call("sleep", "450"))
pause()
present.write("Console 测试\n")
stop()
]]))
        arguments = { harness.lua_command(), script, path.currentDirectory(), path.join(root, "observed") }
    else
        assert(process.prepareNative())
        arguments = { assert(require("luainstaller.posix_host").ready()),
            path.join(root, "normal"), path.join(root, "killed") }
    end
    local ok, output, status = process.outputCommand(fixture, arguments, {}, { timeout_seconds = 30 })
    assert(ok, tostring(output) .. "\nfixture status: " .. tostring(status and status.code)
        .. " / " .. tostring(status and status.reason))
end)
assert(fs.removeTree(root))
assert(called, failure)
print("native progress lifecycle ok")
