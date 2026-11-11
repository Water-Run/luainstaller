--[[
Exclusive directory creation rejects a false-success mkdir race.

Author:
    WaterRun
File:
    exclusive_directory.lua
Date:
    2026-11-12
Updated:
    2026-11-12
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
if package.config:sub(1, 1) ~= "/" then return end
local fs = require("luainstaller.fs")
local process = require("luainstaller.process")
local root = assert(fs.makePrivateDirectory("exclusive-directory"))
local called, failure = pcall(function()
    local bin = root .. "/bin"
    assert(fs.makeDirectory(bin))
    local mkdir = assert(process.firstLine("command -v mkdir"))
    local shim = bin .. "/mkdir"
    assert(fs.writeFile(shim, "#!/bin/sh\n"
        .. "for candidate do target=$candidate; done\n"
        .. "if [ \"$target\" = \"$FALSE_MKDIR_TARGET\" ]; then\n"
        .. "    " .. process.shellQuote(mkdir) .. " -m 700 \"$target\" || exit 1\n"
        .. "    printf '%s\\n' foreign > \"$target/FOREIGN.txt\"\n"
        .. "    exit 0\n"
        .. "fi\nexec " .. process.shellQuote(mkdir) .. " \"$@\"\n"))
    assert(process.output("chmod 700 " .. process.shellQuote(shim)))
    local env = {PATH=bin .. ":" .. (os.getenv("PATH") or "")}
    local failures = {}
    for _, kind in ipairs({"filesystem", "logger"}) do
        local home = root .. "/" .. kind
        assert(fs.makeDirectory(home))
        local target = kind == "logger" and home .. "/.luainstaller/logs.lua.lock"
            or home .. "/claimed"
        env.HOME, env.FALSE_MKDIR_TARGET = home, target
        local driver = root .. "/" .. kind .. ".lua"
        local check = kind == "filesystem" and [[
local created = fs.createDirectory(os.getenv("FALSE_MKDIR_TARGET"))
assert(not created, "mkdir false success was accepted as exclusive creation")
]] or [[
local native = require("luainstaller.posix_host")
native.prepare = function() error("logging requested a compiler", 0) end
local original_time, original_execute = os.time, os.execute
local offset, owner_writes = 0, 0
os.time = function(...) return original_time(...) + offset end
os.execute = function(command)
    local values = {original_execute(command)}
    if command:find("mkdir -m 700", 1, true) then offset = 60 end
    return (table.unpack or unpack)(values, 1, 3)
end
local original_write = fs.writeFile
fs.writeFile = function(path, ...)
    if path:find("logs.lua.lock/owner.", 1, true) then owner_writes = owner_writes + 1 end
    return original_write(path, ...)
end
local written = require("luainstaller.logger").logInfo("test", "race", "foreign lock")
assert(not written, "logger accepted an unowned directory")
assert(owner_writes == 0, "logger wrote inside a lock it did not create")
assert(not native.ready(), "logging compiled a process backend")
]]
        assert(fs.writeFile(driver, harness.loader_prelude() .. [[
local fs = require("luainstaller.fs")
]] .. check .. [[
assert(fs.readFile(os.getenv("FALSE_MKDIR_TARGET") .. "/FOREIGN.txt") == "foreign\n",
    "another creator's contents were changed")
]]))
        local ok, output = process.outputCommand(harness.lua_command(), {driver}, env)
        if not ok then failures[#failures + 1] = kind .. ": " .. tostring(output) end
    end
    assert(#failures == 0, table.concat(failures, "\n"))
end)
assert(fs.removeTree(root))
assert(called, failure)
print("exclusive directory creation rejects false success")
