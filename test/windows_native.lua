--[[
Native Windows process and filesystem backend tests.

Author:
    WaterRun
File:
    windows_native.lua
Date:
    2026-07-14
Updated:
    2026-10-06
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

assert(package.config:sub(1, 1) == "\\", "windows_native.lua must run on Windows")

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local platform = require("luainstaller.platform")
local windows_host = platform.detectHost()
assert(windows_host.arch == "x86" or windows_host.arch == "x86_64"
        or windows_host.arch == "arm" or windows_host.arch == "arm64",
    "Windows tests require a recognized native architecture: " .. windows_host.arch)
assert(platform.profile({ target_os = "windows" }))

-- Any accidental use of the old backend is a test failure.
process.outputPowerShell = function() error("PowerShell must not be used") end
process.inputPowerShell = function() error("PowerShell must not be used") end

local lua = harness.lua_command()
local runtime_analysis = require("luainstaller").analyze({
    entry = "test/runtime_bundle/main.lua",
    discovery_mode = "runtime",
    lua = lua,
})
assert(runtime_analysis.ok,
    runtime_analysis.error and runtime_analysis.error.message or
        "runtime discovery failed on Windows")
assert(#runtime_analysis.dependencies.scripts == 1,
    "Windows runtime discovery omitted the required Lua module")

local argument = "say \"hello\"\\trail\\ & percent% caret^ bang! 测试"
local root, unexpected_root_result = fs.makePrivateDirectory("windows-native")
assert(root, unexpected_root_result)
assert(unexpected_root_result == nil,
    "successful private-directory creation leaked an auxiliary return value")

local fixture = dofile("test/support/windows_fixture.lua")(root)
local flooded, flood_output = process.outputCommand(fixture, { "flood" }, {}, { timeout_seconds = 15 })
assert(flooded and flood_output == string.rep("a", 64 * 4096) .. string.rep("b", 64 * 4096),
    "simultaneous stdout/stderr capture failed")
local timed, timeout_output = process.outputCommand(fixture, { "sleep" }, {}, { timeout_seconds = 0.1 })
assert(not timed and timeout_output:find("timed out", 1, true), timeout_output)

local concurrent_root = path.join(root, "private-directory-concurrency")
assert(fs.makeDirectory(concurrent_root))
local private_worker = path.join(root, "private-directory-worker.lua")
assert(fs.writeFile(private_worker, [[
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local result_path, owner = assert(arg[1]), assert(arg[2])
local directory = assert(fs.makePrivateDirectory("concurrent-private"))
local marker = directory .. "/owner.txt"
assert(fs.writeFile(marker, owner))
local deadline = os.clock() + 0.75
while os.clock() < deadline do end
if fs.readRegularFile(marker) ~= owner then os.exit(41) end
if not fs.removeTree(directory) then os.exit(42) end
assert(fs.writeFile(result_path, directory))
]]))
local concurrent_ok, concurrent_output = process.outputCommand(fixture, {
    "spawn", lua, private_worker, concurrent_root, path.currentDirectory(),
})
assert(concurrent_ok, concurrent_output)
local private_paths = {}
for index = 1, 12 do
    local private_path = assert(fs.readRegularFile(
        path.join(concurrent_root, "result-" .. index .. ".txt")
    ))
    assert(not private_paths[private_path], "private directory path was reused concurrently")
    private_paths[private_path] = true
end
local special = path.join(root, "&A%caret^bang!-测试")
assert(fs.makeDirectory(special))

-- A Unicode-aware native child checks the actual argv and environment;
-- Lua's narrow CRT entry point depends on the system code page.
local ok, output = process.outputCommand(fixture, { "unicode", argument }, {
    LUAI_WINDOWS_ENV = "value & % ^ ! 测试",
})
assert(ok, output)
assert(output == "windows unicode process ok", output)

local failed = process.outputCommand(lua, { "-e", "os.exit(7)" })
assert(failed == false, "non-zero child exit was reported as success")
local harness_ok, harness_output, harness_status = harness.command_result(
    '<nul set /p "=harness-status-output"&exit /b 7'
)
assert(not harness_ok, "Lua 5.1-compatible harness reported exit 7 as success")
assert(harness_status == 7,
    "Lua 5.1-compatible harness lost child status: " .. tostring(harness_status))
assert(harness_output == "harness-status-output",
    "Lua 5.1-compatible harness lost child output: " .. tostring(harness_output))

local original = path.join(special, "original.txt")
local copied = path.join(special, "copied.txt")
assert(fs.writeFile(original, "native windows bytes\n"))
assert(fs.copyFile(original, copied))
assert(fs.pathType(original) == "file")
assert(fs.pathType(special) == "directory")
assert(fs.readRegularFile(copied) == "native windows bytes\n")

local large = path.join(special, "large-binary.bin")
local large_content = string.rep("\0\255LuaInstaller\r\n", 9000)
assert(#large_content > 128 * 1024)
assert(fs.writeFile(large, large_content))
assert(fs.readRegularFile(large) == large_content)

local target = path.join(root, "junction-target")
local junction = path.join(root, "junction")
assert(fs.makeDirectory(target))
local junction_ok, junction_output = process.outputCommand(fixture, {
    "junction", junction, target,
})
assert(junction_ok, junction_output)
assert(fs.pathType(junction) == "reparse")

assert(not fs.writeFile(path.join(junction, "escaped.txt"), "unsafe"))
assert(fs.pathType(path.join(target, "escaped.txt")) == "missing")
assert(not fs.copyFile(original, path.join(junction, "copied.txt")))
assert(not fs.makeDirectory(path.join(junction, "nested")))

local owner_worker = path.join(root, "owner-worker.lua")
assert(fs.writeFile(owner_worker, [[
local harness = dofile("test/support/harness.lua")
harness.install_loader()
require("luainstaller.process").outputCommand(arg[1], { "tree", arg[2] }, {}, { timeout_seconds = 30 })
]]))
local owner_ok, owner_output = process.outputCommand(fixture, {
    "owner", lua, owner_worker, path.join(root, "owner-ready.txt"), path.currentDirectory(),
}, {}, { timeout_seconds = 20 })
assert(owner_ok and owner_output:find("owner death contained descendants", 1, true), owner_output)

local entries = assert(fs.listTree(root))
local seen_original = false
for _, entry in ipairs(entries) do
    if entry.path:match("original%.txt$") and entry.type == "file" then
        seen_original = true
    end
end
assert(seen_original, "listTree omitted a regular file")

local logger_home = path.join(root, "home &A%caret^bang!-日志")
assert(fs.makeDirectory(logger_home))
local logger_child = path.join(root, "logger-child.lua")
assert(fs.writeFile(logger_child, [[
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local logger = require("luainstaller.logger")
assert(logger.clearLogs())
assert(logger.logInfo("windows-native", "round-trip", "日志 & % ^ !"))
local logs = logger.getLogs({ source = "windows-native" })
assert(#logs == 1)
assert(logs[1].message == "日志 & % ^ !")
io.write("windows logger ok")
]]))
local logger_ok, logger_output = process.outputCommand(lua, { logger_child }, {
    HOME = logger_home,
    USERPROFILE = logger_home,
    PATH = "C:\\Windows\\System32;C:\\Windows",
})
assert(logger_ok, logger_output)
assert(logger_output == "windows logger ok", logger_output)

local removed, remove_error = fs.removeTree(root)
assert(not removed and tostring(remove_error):find("reparse", 1, true),
    "tree cleanup followed or ignored a reparse point")
assert(fs.removeFile(junction))
assert(fs.removeTree(root))
assert(fs.pathType(root) == "missing")

print("windows native process and filesystem ok")
