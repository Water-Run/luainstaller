--[[
1.8.1 command surface: JSON, display flags, equals-form options, and progress.

Author:
    WaterRun
File:
    cli_surface.lua
Date:
    2026-10-19
Updated:
    2026-10-19
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local cli = require("luainstaller.cli")
local present = require("luainstaller.cli_present")
local logger = require("luainstaller.logger")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local windows = package.config:sub(1, 1) == "\\"

local function assert_contains(haystack, needle)
    if not tostring(haystack):find(needle, 1, true) then
        error(string.format("expected %q in:\n%s", needle, tostring(haystack)), 2)
    end
end

local function run_cli(program_name, args, context)
    local stdout, stderr = {}, {}
    local old_io = io
    local fake = {}
    for key, value in pairs(old_io) do fake[key] = value end
    fake.write = function(...)
        for index = 1, select("#", ...) do
            stdout[#stdout + 1] = tostring(select(index, ...))
        end
    end
    fake.stderr = { write = function(_, ...)
        for index = 1, select("#", ...) do
            stderr[#stderr + 1] = tostring(select(index, ...))
        end
    end }
    _G.io = fake
    context = context or {}
    context.program_name = program_name
    context.animations = false
    local ok, code = pcall(cli.main, args, context)
    _G.io = old_io
    if not ok then error(code, 2) end
    return code, table.concat(stdout), table.concat(stderr)
end

local code, out, err = run_cli("luainstaller", { "--format", "json", "version" })
assert(code == 0, err)
assert(err == "")
assert_contains(out, '"schema_version":1')
assert_contains(out, '"command":"version"')
assert_contains(out, '"ok":true')
assert_contains(out, '"version":"1.8.1"')
assert(not out:find("\27[", 1, true))

code, out, err = run_cli("luainstaller", { "version", "--format=json" })
assert(code == 0 and out:find('"command":"version"', 1, true), err)

code, out, err = run_cli("luainstaller", { "--format", "yaml", "version" })
assert(code == 1)
assert_contains(err, "--format must be text or json")

code, out, err = run_cli("luainstaller", { "help", "analyze" })
assert(code == 0, err)
assert_contains(out, "Command: analyze")
assert_contains(out, "--format <text|json>")
assert_contains(out, "--max-deps")

code, out, err = run_cli("luainstaller", { "version", "extra" })
assert(code == 1)
assert_contains(err, "version does not take extra arguments")

code, out, err = run_cli("luai", { "-h", "extra" })
assert(code == 1)
assert_contains(err, "help does not take extra arguments")

code, out, err = run_cli("luai", { "-a", "test/runtime_bundle/main.lua", "--max-deps=4" })
assert(code == 0, err)
assert_contains(out, "scripts:")
assert(not out:find("\27[", 1, true))

code, out, err = run_cli("luainstaller", {
    "--format", "json", "analyze", "test/runtime_bundle/main.lua", "--max-deps", "4",
})
assert(code == 0, err)
assert(err == "")
assert_contains(out, '"command":"analyze"')
assert_contains(out, '"ok":true')
assert(not out:find("Analysis complete", 1, true))

code, out, err = run_cli("luainstaller", { "analyze", "example.lua", "--verbose=1" })
assert(code == 1)
assert_contains(err, "--verbose does not take a value")

local original = logger.queryLogs
logger.queryLogs = function()
    return { ok = false, status = "unreadable", logs = {} }
end
code, out, err = run_cli("luainstaller", { "logs" })
logger.queryLogs = original
assert(code == 1)
assert_contains(err, "LogReadError: log file is unreadable")

logger.queryLogs = function()
    return { ok = true, status = "backup", logs = {
        { timestamp = "2026-10-19T00:00:00Z", level = "info", source = "api",
          action = "analyze", message = "recovered" },
    } }
end
code, out, err = run_cli("luai", { "-l" })
logger.queryLogs = original
assert(code == 0, err)
assert_contains(out, "recovered")
assert_contains(err, "using recovered log copy")

local ticks = { 0 }
local progress = present.newProgress({
    mode = "plain",
    interval = 1,
    clock = function() return ticks[1] end,
    write = function() end,
})
assert(present.progressEvent(progress, { phase = "scan", state = "running" }) == true)
ticks[1] = 0.01
assert(present.progressEvent(progress, { phase = "scan", state = "running", done = 1, total = 3 }) == false)
ticks[1] = 1
assert(present.progressEvent(progress, { phase = "scan", state = "success", done = 3, total = 3 }) == true)
assert(#progress.events == 3)
assert(progress.rendered == 2)

local encoded = present.encodeJson({ ok = true, items = { "a", 'b"c' }, n = 1 })
assert(encoded:find('"ok":true', 1, true))
assert(encoded:find('"b\\"c"', 1, true))

local version = require("luainstaller").VERSION
assert(version == "1.8.1")
code, out, err = run_cli("luai", { "-v" })
assert(code == 0 and out == "luai " .. version .. "\n" and err == "", out .. err)

code, out, err = run_cli("luainstaller", { "--format", "json", "help" })
assert(code == 0 and err == "", err)
for _, field in ipairs({ '"schema_version":', '"command":"help"', '"ok":true',
    '"result":', '"warnings":', '"error":null' }) do
    assert_contains(out, field)
end

code, out, err = run_cli("luainstaller", { "--format", "json", "missing-command" })
assert(code ~= 0)
assert(err == "")
assert_contains(out, '"ok":false')
assert_contains(out, '"error":')
assert(not out:find("\27[", 1, true))
assert(not out:find("Analyzing", 1, true))

local entry = "test/runtime_bundle/main.lua"
local classic_ok = run_cli("luai", { "-a", entry, "--max-deps", "4" })
local modern_ok = run_cli("luainstaller", { "analyze", entry, "--max-deps", "4" })
assert(classic_ok == 0 and modern_ok == 0)
local classic_bad = run_cli("luai", { "-a", "test/missing-entry.lua" })
local modern_bad = run_cli("luainstaller", { "analyze", "test/missing-entry.lua" })
assert(classic_bad ~= 0 and modern_bad ~= 0)

code, out, err = run_cli("luainstaller", {
    "--no-color", "analyze", entry, "--max-deps", "4",
})
assert(code == 0, err)
assert(not out:find("\27[", 1, true))

code, out, err = run_cli("luainstaller", {
    "--color", "always", "analyze", entry, "--max-deps", "4",
})
assert(code == 0, err)
assert_contains(out, "\27[")

code, out, err = run_cli("luainstaller", {
    "--progress", "plain", "analyze", entry, "--max-deps", "4",
})
assert(code == 0, err)
assert_contains(err, "Analyzing")
assert(not out:find("Analyzing", 1, true))

code, out, err = run_cli("luainstaller", {
    "--format", "json", "--progress", "plain", "--color", "always",
    "analyze", entry, "--max-deps", "4",
})
assert(code == 0, err)
assert(err == "")
assert(not out:find("\27[", 1, true))
assert_contains(out, '"error":null')

code, out, err = run_cli("luainstaller", { "--no-progress", "version" })
assert(code == 0 and err == "", err)
code, out, err = run_cli("luainstaller", { "--progress", "off", "version" })
assert(code == 0 and err == "", err)

logger.queryLogs = function()
    return { ok = true, status = "empty", logs = {} }
end
code, out, err = run_cli("luainstaller", { "logs" })
logger.queryLogs = original
assert(code == 0 and out == "No logs found.\n", out .. err)

local listed = logger.getLogs({})
assert(type(listed) == "table")
local count = 0
for index, record in ipairs(listed) do
    count = index
    assert(type(record) == "table")
end
assert(count == #listed)

local probe_dir = assert(fs.makePrivateDirectory("version-cc-probe"))
local marker = path.join(probe_dir, "probed")
local compiler = path.join(probe_dir, windows and "cc.cmd" or "cc")
if windows then
    assert(fs.writeFile(compiler, '@echo off\r\nsetlocal DisableDelayedExpansion\r\necho invoked>"'
        .. marker:gsub("%%", "%%%%") .. '"\r\nexit /b 1\r\n'))
else
    assert(fs.writeFile(compiler, "#!/bin/sh\nprintf invoked > " .. process.shellQuote(marker) .. "\nexit 1\n"))
    assert(fs.setExecutable(compiler))
end
local lua = harness.lua_command()
local probe = 'dofile("test/support/harness.lua").install_loader();'
    .. 'os.exit(require("luainstaller.cli").main({"version"},'
    .. '{program_name="luainstaller",animations=false,color=false}))'
local probed, probe_output = process.outputCommand(lua, {"-e", probe}, {
    LUAI_CC = compiler, LUAI_HOST_CC = compiler, CC = compiler,
})
assert(probed, probe_output)
assert(fs.pathType(marker) == "missing", "version launched a compiler probe")

assert(progress.events[#progress.events].state == "success")

local function assert_json_failure(args, command)
    local failed_code, failed_out, failed_err = run_cli("luainstaller", args)
    assert(failed_code ~= 0, failed_out .. failed_err)
    assert(failed_err == "", failed_err)
    assert_contains(failed_out, '"schema_version":1')
    assert_contains(failed_out, '"command":"' .. command .. '"')
    assert_contains(failed_out, '"ok":false')
    assert_contains(failed_out, '"result":null')
    assert_contains(failed_out, '"warnings":')
    assert_contains(failed_out, '"error":')
    assert(not failed_out:find("\27[", 1, true))
    assert(not failed_out:find("Analyzing", 1, true))
end

assert_json_failure({
    "--format", "json", "analyze", "example.lua", "--verbose=1",
}, "analyze")
assert_json_failure({
    "--format", "json", "--color", "purple", "version",
}, "version")
assert_json_failure({
    "--format", "json", "logs", "--limit", "nope",
}, "logs")

local auto = { color = "auto", progress = "auto", format = "text" }
assert(present.commandSucceeded(true) == true)
assert(present.commandSucceeded(0) == true)
assert(present.commandSucceeded(1) == false)
assert(present.commandSucceeded(false) == false)
assert(present.wantColor({ color = "always", format = "text" }, { color = false }, false) == true)
assert(present.wantColor({ color = "never", format = "text" }, { color = true }, true) == false)
assert(present.wantColor({ color = "auto", format = "json" }, {}, true) == false)
assert(present.wantProgress({ progress = "plain", format = "text" }, { animations = false }, false) == "plain")
assert(present.wantProgress(auto, {}, false) == "off")
assert(present.wantProgress({ progress = "auto", format = "json" }, {}, true) == "off")

local function policy_result(environment, tty)
    local getenv = os.getenv
    os.getenv = function(name) return environment[name] end
    local called, text = pcall(function()
        return (present.wantColor(auto, {}, tty, false) and "color-yes" or "color-no")
            .. " " .. present.wantProgress(auto, {}, tty)
    end)
    os.getenv = getenv
    assert(called, text)
    return text
end
assert(policy_result({TERM="xterm"}, true) == "color-yes redraw")
assert(policy_result({TERM="xterm"}, false) == "color-no off")
assert(policy_result({NO_COLOR="1", TERM="xterm"}, true) == "color-no redraw")
assert(policy_result({TERM="dumb"}, true) == "color-no off")
assert(policy_result({CI="1", TERM="xterm"}, true) == "color-no off")

local saw_tty = nil
local original_color = present.wantColor
present.wantColor = function(display, context, stdout_is_tty)
    saw_tty = stdout_is_tty
    return original_color(display, context, stdout_is_tty)
end
code, out, err = run_cli("luainstaller", { "--color", "auto", "version" })
present.wantColor = original_color
assert(code == 0, err)
assert(type(saw_tty) == "boolean")

local function run_real_logs(home)
    local runner = home .. "/run-logs.lua"
    local script = assert(io.open(runner, "w"))
    script:write(string.format([[
dofile("test/support/harness.lua").install_loader()
local cli = require("luainstaller.cli")
local logger = require("luainstaller.logger")
local output = assert(io.open(%q, "wb"))
local errors = assert(io.open(%q, "wb"))
io.write = function(...) return output:write(...) end
io.stderr = errors
local code = cli.main({"logs"}, { program_name = "luainstaller", animations = false, color = false })
local logs = logger.getLogs({})
local result = assert(io.open(%q, "w"))
result:write("CODE=" .. tostring(code) .. "\n")
result:write("COUNT=" .. tostring(#logs) .. "\n")
result:write(type(logs) == "table" and "LIST=yes\n" or "LIST=no\n")
if logs[1] then result:write("MSG=" .. tostring(logs[1].message) .. "\n") end
result:close()
output:close()
errors:close()
os.exit(0)
]], home .. "/stdout.txt", home .. "/stderr.txt", home .. "/result.txt"))
    script:close()
    local ran, diagnostic = process.outputCommand(harness.lua_command(), {runner}, {
        HOME = home, USERPROFILE = home,
    })
    assert(ran, diagnostic)
    local result_handle = assert(io.open(home .. "/result.txt", "r"))
    local text = result_handle:read("*a")
    result_handle:close()
    local stdout_handle = assert(io.open(home .. "/stdout.txt", "r"))
    local stdout = stdout_handle:read("*a")
    stdout_handle:close()
    local stderr_handle = assert(io.open(home .. "/stderr.txt", "r"))
    local stderr = stderr_handle:read("*a")
    stderr_handle:close()
    return text, stdout, stderr
end

local empty_home = assert(fs.makePrivateDirectory("logs-empty"))
local empty_text, empty_out, empty_err = run_real_logs(empty_home)
assert(empty_text:find("CODE=0", 1, true), empty_text)
assert(empty_text:find("COUNT=0", 1, true), empty_text)
assert(empty_text:find("LIST=yes", 1, true), empty_text)
assert(empty_out:find("No logs found.", 1, true), empty_out)
assert(not empty_err:find("recovered", 1, true))
assert(not empty_err:find("unreadable", 1, true))

local bad_home = assert(fs.makePrivateDirectory("logs-bad"))
assert(fs.makeDirectory(bad_home .. "/.luainstaller"))
local bad_file = assert(io.open(bad_home .. "/.luainstaller/logs.lua", "w"))
bad_file:write("this is not a log\n")
bad_file:close()
local bad_text, bad_out, bad_err = run_real_logs(bad_home)
assert(bad_text:find("CODE=1", 1, true), bad_text .. bad_err)
assert(bad_text:find("COUNT=0", 1, true), bad_text)
assert(bad_text:find("LIST=yes", 1, true), bad_text)
assert(bad_err:find("unreadable", 1, true), bad_err)
assert(not bad_out:find("No logs found.", 1, true))

local backup_home = assert(fs.makePrivateDirectory("logs-backup"))
assert(fs.makeDirectory(backup_home .. "/.luainstaller"))
local backup_file = assert(io.open(backup_home .. "/.luainstaller/logs.lua.bak", "w"))
backup_file:write([[
return {
    {
        timestamp = "2026-10-19T00:00:00Z",
        level = "info",
        source = "api",
        action = "analyze",
        message = "backup record",
        details = {},
    },
}
]])
backup_file:close()
local backup_text, backup_out, backup_err = run_real_logs(backup_home)
assert(backup_text:find("CODE=0", 1, true), backup_text .. backup_out .. backup_err)
assert(backup_text:find("COUNT=1", 1, true), backup_text)
assert(backup_text:find("LIST=yes", 1, true), backup_text)
assert(backup_text:find("MSG=backup record", 1, true), backup_text)
assert(backup_out:find("backup record", 1, true), backup_out)
assert(backup_err:find("using recovered log copy", 1, true), backup_err)

assert(present.displayWidth("中文") == 4)
assert(present.displayWidth("ab") == 2)
assert(present.displayWidth("\1") == 4)
assert(present.displayWidth(string.char(0xF0, 0x9F, 0x99, 0x82)) == 2)
assert(present.displayWidth("a" .. string.char(0xCC, 0x81)) == 1)
assert(present.displayWidth(string.char(0xE4, 0x41)) == 2)
assert(present.visible("\1") == "\\x01")
assert(present.fit("中文中文中文", 5) == "中文…")
assert(type(present.streamIsTTY(1, true)) == "boolean")
assert(type(present.streamIsTTY(2, true)) == "boolean")
assert(present.colorLevel(function(name)
    return name == "COLORTERM" and "truecolor" or ""
end, true) == "truecolor")
assert(present.colorLevel(function(name)
    return name == "TERM" and "xterm-256color" or ""
end, true) == "256")
assert(present.colorLevel(function() return "" end, false) == "none")
assert(present.windowsVT(function(name)
    return name == "WT_SESSION" and "session" or ""
end) == true)
assert(present.windowsVT(function(name)
    return name == "ConEmuANSI" and "ON" or ""
end) == true)
assert(present.windowsVT(function() return "" end) == false)
local windows_vt = present.windowsVT
present.windowsVT = function() return false end
assert(present.wantColor({ color = "auto", progress = "auto", format = "text" }, {}, true, true) == false)
present.windowsVT = windows_vt

if not windows then
    local sink_dir = assert(fs.makePrivateDirectory("redraw-frames"))
    local sink = path.join(sink_dir, "frames")
    local stop = present.startRedraw("编译", sink)
    local frames = ""
    local deadline = os.time() + 3
    repeat
        assert(process.outputCommand("sh", {"-c", "sleep 0.2"}))
        frames = fs.readRegularFile(sink) or ""
    until frames:find("编译", 1, true) or os.time() >= deadline
    stop()
    assert(frames:find("编译", 1, true), frames)
    assert(frames:find("[", 1, true), frames)
    assert(fs.removeTree(sink_dir))
end
for _, directory in ipairs({probe_dir, empty_home, bad_home, backup_home}) do
    assert(fs.removeTree(directory))
end

print("cli surface ok")
