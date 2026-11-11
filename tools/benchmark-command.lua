--[[
Run one benchmark command through the project's native process supervisor.

Author:
    WaterRun
File:
    benchmark-command.lua
Date:
    2026-11-11
Updated:
    2026-11-11
]]

local directory = assert(arg[0]:match("^(.*[/\\])"), "run this helper through its tools path")
dofile(directory .. "../luainstaller.lua")
local process = require("luainstaller.process")
local arguments = {}
for i = 3, #arg do arguments[#arguments + 1] = arg[i] end
local ok, output, state = process.outputCommand(arg[2], arguments, {}, {
    timeout_seconds=tonumber(arg[1]), max_output_bytes=8388608,
})
local wrote = io.stdout:write(output or "")
local flushed = io.stdout:flush()
if not wrote or not flushed then os.exit(74) end
if ok then os.exit(0) end
-- Supervisor failures must not look like an application's expected rejection.
if state.reason == "timeout" then os.exit(124) end
if state.reason == "output-limit" then os.exit(125) end
if state.reason ~= "exit" then os.exit(126) end
os.exit(state.code or 126)
