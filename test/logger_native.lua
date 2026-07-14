--[[
Native logger persistence smoke test.

Author:
    WaterRun
File:
    logger_native.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()

local logger = require("luainstaller.logger")
assert(logger.clearLogs())
assert(logger.logInfo("native-smoke", "round-trip", "日志 & % ^ !"))
local logs = logger.getLogs({ source = "native-smoke" })
assert(#logs == 1)
assert(logs[1].message == "日志 & % ^ !")

print("native logger ok: " .. _VERSION)
