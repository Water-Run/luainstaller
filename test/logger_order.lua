--[[
Equal-timestamp logs retain insertion order before filtering and limiting.

Author:
    WaterRun
File:
    logger_order.lua
Date:
    2026-10-15
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("logger-order"))
local environment_variable, date = process.environmentVariable, os.date
local timestamp = "2026-01-02T00:00:00Z"
process.environmentVariable = function(name)
    if name == "HOME" or name == "USERPROFILE" then return root end
    return environment_variable(name)
end
os.date = function(format, ...)
    if format == "!%Y-%m-%dT%H:%M:%SZ" then return timestamp end
    return date(format, ...)
end
local called, failure = pcall(function()
    local logger = require("luainstaller.logger")
    assert(logger.logInfo("order", "write", "first"))
    assert(logger.logInfo("order", "write", "second"))
    local latest = logger.getLogs({source="order", limit=1})
    assert(#latest == 1 and latest[1].message == "second", "latest log with equal timestamp was lost")
    timestamp = "2026-01-01T00:00:00Z"
    assert(logger.logInfo("order", "write", "earlier-timestamp"))
    timestamp = "2026-01-02T00:00:00Z"
    assert(logger.logWarning("other", "write", "filtered-out"))
    for _, descending in ipairs({false, true}) do
        local logs = logger.getLogs({source="order", level="info", descending=descending})
        local expected = descending and {"second", "first", "earlier-timestamp"}
            or {"earlier-timestamp", "first", "second"}
        assert(#logs == #expected)
        for index, message in ipairs(expected) do
            assert(logs[index].message == message, "log order changed at " .. index)
        end
    end
    for _, program in ipairs({"luai", "luainstaller"}) do
        local code, output = harness.invoke_cli(program, {program == "luai" and "-l" or "logs",
            "--level", "info", "--limit", "1"})
        assert(code == 0)
        harness.assert_contains(output, "second")
        harness.assert_not_contains(output, "first")
        local ascending, oldest = harness.invoke_cli(program, {program == "luai" and "-l" or "logs",
            "--level", "info", "--limit", "1", "--asc"})
        assert(ascending == 0)
        harness.assert_contains(oldest, "earlier-timestamp")
    end
    assert(fs.pathType(path.join(root, ".luainstaller")) == "directory")
end)
process.environmentVariable, os.date = environment_variable, date
assert(fs.removeTree(root))
assert(called, failure)
print("equal-timestamp log ordering ok")
