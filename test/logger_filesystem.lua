--[[
Logger file transactions do not depend on optional process-output supervision.

Author:
    WaterRun
File:
    logger_filesystem.lua
Date:
    2026-11-12
Updated:
    2026-11-12
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local fs = require("luainstaller.fs")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("logger-filesystem"))
local called, failure = pcall(function()
    local home = root .. "/home"
    assert(fs.makeDirectory(home))
    local driver = root .. "/driver.lua"
    assert(fs.writeFile(driver, harness.loader_prelude() .. [[
local native = require("luainstaller.posix_host")
native.prepare = function() error("logging requested a compiler", 0) end
local logger = require("luainstaller.logger")
assert(logger.logInfo("test", "filesystem", "before"))
local process = require("luainstaller.process")
local fs = require("luainstaller.fs")
local original_output, original_write = process.output, fs.writeFile
fs.writeFile = function(...)
    process.output = function() return false, "capture unavailable", {reason="supervisor-error"} end
    return original_write(...)
end
local written, err = logger.logInfo("test", "filesystem", "after")
process.output, fs.writeFile = original_output, original_write
assert(written, "filesystem logging depends on capture supervision: " .. tostring(err))
local logs = logger.getLogs({descending=false})
assert(#logs == 2 and logs[1].message == "before" and logs[2].message == "after",
    "a capture failure changed existing log content")
assert(not native.ready(), "filesystem logging compiled a process backend")
print("logger filesystem transaction remained available")
]]))
    local ok, output = process.outputCommand(harness.lua_command(), {driver}, {HOME=home})
    assert(ok, output)
end)
assert(fs.removeTree(root))
assert(called, failure)
print("logger filesystem independence ok")
