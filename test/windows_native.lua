--[[
Native Windows process and filesystem backend tests.

Author:
    WaterRun
File:
    windows_native.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

assert(package.config:sub(1, 1) == "\\", "windows_native.lua must run on Windows")

local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")

local lua = harness.lua_command()
local argument = "say \"hello\"\\trail\\ & percent% caret^ bang! 测试"
local shell_ok, shell_output = process.outputPowerShell(
    "[Console]::Write([Text.Encoding]::UTF8.GetString(" ..
        "[Convert]::FromBase64String('5rWL6K+VICYgJSBeICE=')))"
)
assert(shell_ok and shell_output == "测试 & % ^ !", tostring(shell_output))
local long_unicode_ok, long_unicode_output = process.outputPowerShell(
    string.rep("$null=1;", 1000)
        .. "[Console]::Write([Text.Encoding]::UTF8.GetString("
        .. "[Convert]::FromBase64String('6ZW/6ISa5pys6Zuq')))"
)
assert(long_unicode_ok and long_unicode_output == "长脚本雪", tostring(long_unicode_output))
local root = assert(fs.makePrivateDirectory("windows-native"))
local special = path.join(root, "&A%caret^bang!-测试")
assert(fs.makeDirectory(special))

local child = path.join(special, "argv.lua")
assert(fs.writeFile(child, [[
io.write(arg[1] or "")
io.write("\31")
io.write(os.getenv("LUAI_WINDOWS_ENV") or "")
]]))

local ok, output = process.outputCommand(lua, { child, argument }, {
    LUAI_WINDOWS_ENV = "value & % ^ ! 测试",
})
assert(ok, output)
assert(output == argument .. "\31value & % ^ ! 测试", output)

local failed = process.outputCommand(lua, { "-e", "os.exit(7)" })
assert(failed == false, "non-zero child exit was reported as success")

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
local powershell = assert(process.windowsPowerShellPath())
local junction_script = [[
& {
    param([string]$Link, [string]$Target)
    $ErrorActionPreference = 'Stop'
    New-Item -ItemType Junction -Path $Link -Target $Target -ErrorAction Stop | Out-Null
}]]
local junction_ok, junction_output = process.outputCommand(powershell, {
    "-NoLogo",
    "-NoProfile",
    "-NonInteractive",
    "-Command",
    junction_script,
    (junction:gsub("/", "\\")),
    (target:gsub("/", "\\")),
})
assert(junction_ok, junction_output)
assert(fs.pathType(junction) == "reparse")

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
local logger_child = path.join(special, "logger-child.lua")
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
