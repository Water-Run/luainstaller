--[[
Commands can run in a private directory without changing the caller's cwd.

Author:
    WaterRun
File:
    process_working_directory.lua
Date:
    2026-10-13
Updated:
    2026-10-13
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local process = require("luainstaller.process")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local root = assert(fs.makePrivateDirectory("command-cwd"))
local private = path.join(root, "spaces & percent % directory")
assert(fs.makeDirectory(private))
assert(fs.writeFile(path.join(private, "marker.txt"), "private-command-directory"))
local called, failure = pcall(function()
    local ran, output = process.outputCommand(harness.lua_command(), {
        "-e", 'local f=assert(io.open("marker.txt","rb")); io.write(f:read("*a")); assert(f:close())',
    }, {}, {working_directory=private})
    assert(ran and output == "private-command-directory", output)
    local failed, _, status = process.outputCommand(harness.lua_command(), {"-e", "os.exit(0)"},
        {}, {working_directory=path.join(root, "missing")})
    assert(not failed and status and status.code ~= 0,
        "a missing command directory was silently ignored")
    local invalid, _, invalid_status = process.outputCommand(harness.lua_command(), {"-e", "os.exit(0)"},
        {}, {working_directory="bad\0directory"})
    assert(not invalid and invalid_status and invalid_status.reason == "invalid-options")
    assert(fs.pathType("marker.txt") == "missing", "command changed the caller directory")
end)
assert(fs.removeTree(root))
assert(called, failure)
print("private command working directory ok")
