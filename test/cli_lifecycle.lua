--[[
CLI calls preserve caller settings and release presentation resources on failure.

Author:
    WaterRun
File:
    cli_lifecycle.lua
Date:
    2026-10-19
Updated:
    2026-10-19
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local cli = require("luainstaller.cli")
local api = require("luainstaller")
local present = require("luainstaller.cli_present")
local original_io, original_analyze = io, api.analyze
local original_tty, original_redraw = present.streamIsTTY, present.startRedraw
local original_policy = present.wantProgress
local original_write = present.write
local failures, started, stopped, output, diagnostic = {}, 0, 0, {}, {}
local function check(value, label)
    if not value then failures[#failures + 1] = label end
end
local fake = {}
for key, value in pairs(io) do fake[key] = value end
fake.write = function(value) output[#output + 1] = value; return true end
fake.stderr = { write = function(_, value) diagnostic[#diagnostic + 1] = value; return true end }
_G.io = fake
present.streamIsTTY = function() return true end
present.wantProgress = function(display) return display.format == "json" and "off" or "redraw" end
present.startRedraw = function()
    started = started + 1
    local closed = false
    return function()
        if not closed then stopped = stopped + 1; closed = true end
    end
end
api.analyze = function() error({ type = "InjectedError", message = "injected API failure" }) end
local context = { program_name = "luainstaller", color = false }
local called, code = pcall(cli.main, { "analyze", "test/runtime_bundle/main.lua" }, context)
check(called and code == 1, "API exception escaped CLI boundary")
check(started == 1 and stopped == 1, "API exception leaked progress")
check(context.format == nil and context.progress_mode == nil and context.color == false,
    "CLI changed caller context")
check(table.concat(diagnostic):find("InjectedError", 1, true), "exception diagnostic was lost")

output, diagnostic = {}, {}
called, code = pcall(cli.main, { "--format=json", "analyze", "test/runtime_bundle/main.lua" }, context)
check(called and code == 1 and table.concat(output):find('"ok":false', 1, true)
    and table.concat(output):find('"type":"InjectedError"', 1, true), "API exception lost JSON envelope")
check(table.concat(diagnostic) == "", "JSON exception wrote a second diagnostic")

api.analyze = function()
    return { ok = true, entry = "main.lua", dependencies = { scripts = {}, libraries = {} } }
end
fake.write = function() return nil, "injected full disk" end
called, code = pcall(cli.main, { "analyze", "test/runtime_bundle/main.lua" }, context)
check(called and code == 1, "output failure reported success or escaped")
check(started == 2 and stopped == 2, "output failure leaked progress")
check(table.concat(diagnostic):find("OutputError", 1, true), "output failure lacked useful diagnostic")

fake.write = function() return true end
fake.stdout = { flush = function() return nil, "injected flush failure" end }
called, code = pcall(cli.main, { "version" }, context)
check(called and code == 1, "buffered output failure reported success")

fake.stdout = original_io.stdout
local original_info, prepared = present.consoleInfo, 0
present.consoleInfo = function(_, prepare)
    if prepare then prepared = prepared + 1 end
    return nil
end
for _, args in ipairs({ {"version"}, {"help"}, {"build", "--help"},
    {"analyze", "test/runtime_bundle/main.lua", "--missing-option"} }) do
    pcall(cli.main, args, context)
end
check(prepared == 0, "help, version or invalid options prepared a native compiler")
present.consoleInfo = original_info

_G.io, api.analyze = original_io, original_analyze
present.streamIsTTY, present.startRedraw, present.write = original_tty, original_redraw, original_write
present.wantProgress = original_policy
assert(#failures == 0, table.concat(failures, "\n"))
print("CLI presentation lifecycle ok")
