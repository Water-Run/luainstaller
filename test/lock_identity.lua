--[[
Process identity prevents PID reuse from keeping a stale lock alive.

Author:
    WaterRun
File:
    lock_identity.lua
Date:
    2026-10-12
Updated:
    2026-10-15
]]

local harness = dofile("test/support/harness.lua")
harness.install_loader()
local owner = require("luainstaller.lock_owner")
local pid = assert(owner.currentPid())
local identity = assert(owner.currentIdentity(), "cannot identify the running process")
local platform, scope, birth = identity:match("^([%w]+):([0-9a-f]+):([%w]+)$")
assert(platform and #scope == 64 and birth)
assert(owner.isAlive(pid, identity) == true, "current process was not recognized")
local replacement = platform .. ":" .. scope .. ":" .. (birth == "0" and "1" or "0")
assert(owner.isAlive(pid, replacement) == false, "reused PID retained the previous owner")
local foreign_scope = scope == string.rep("0", 64) and string.rep("1", 64) or string.rep("0", 64)
assert(owner.isAlive(pid, platform .. ":" .. foreign_scope .. ":" .. birth) == nil,
    "a foreign host or PID namespace was treated as dead")
local record = {token=string.rep("a", 64), pid=pid, created=os.time(), identity=identity}
local encoded = assert(owner.encode(record))
local decoded = assert(owner.decode(encoded))
assert(decoded.identity == identity and owner.same(record, decoded))
decoded.identity = replacement
assert(not owner.same(record, decoded), "process identity was omitted from owner comparison")
record.identity = nil
assert(owner.decode(assert(owner.encode(record))).identity == nil, "legacy owner format changed")
assert(not owner.decode(encoded:gsub(identity, "bad-identity", 1)), "malformed identity was accepted")
if platform == "linux" then
    local original_open, closed = io.open, 0
    io.open = function(path, mode)
        if path:sub(1, 6) == "/proc/" then
            return {read=function() error("injected read failure") end,
                close=function() closed=closed+1; return true end}
        end
        return original_open(path, mode)
    end
    local called, unavailable = pcall(owner.currentIdentity)
    io.open = original_open
    assert(called and unavailable == nil and closed > 0,
        "identity read failure raised or leaked its file handle")
end
if package.config:sub(1, 1) == "\\" then
    local fs = require("luainstaller.fs")
    local path = require("luainstaller.path")
    local process = require("luainstaller.process")
    local root = assert(fs.makePrivateDirectory("retained-process"))
    local called, failure = pcall(function()
        local fixture = dofile("test/support/windows_fixture.lua")(root)
        local observer = path.join(root, "observe.lua")
        local evidence = path.join(root, "observed.txt")
        assert(fs.writeFile(observer, harness.loader_prelude() .. string.format([[
local host = require("luainstaller.windows_host")
local owner = require("luainstaller.lock_owner")
local hash = require("luainstaller.hash")
local pid = assert(arg[1])
local readable, value = host.call("identity", pid)
assert(readable, value)
local machine, birth = value:match("^([^\r\n]+)\n([0-9a-f]+)$")
assert(machine and #birth == 16)
local identity = "windows:" .. hash.sha256(machine) .. ":" .. birth
local bare = owner.isAlive(pid)
local identified = owner.isAlive(pid, identity)
assert(require("luainstaller.fs").writeFile(%q, "identity_readable=true\npid_alive="
    .. tostring(bare) .. "\nidentity_alive=" .. tostring(identified) .. "\n"))
assert(bare == false, "fixture child did not exit")
assert(identified == false, "exited process with a retained handle kept its lock alive")
]], evidence)))
        local ran, output = process.outputCommand(fixture, {"held-exit", harness.lua_command(),
            observer, path.currentDirectory()}, {}, {timeout_seconds=120})
        local proof = fs.readRegularFile(evidence)
        assert(ran, tostring(output) .. "\n" .. tostring(proof))
        assert(proof and proof:find("identity_alive=false", 1, true), proof)
        print("retained exited Windows process is not alive")
    end)
    assert(fs.removeTree(root))
    assert(called, failure)
else
    local previous_config = package.config
    local previous_host = package.loaded["luainstaller.windows_host"]
    local state = "no"
    package.config = "\\" .. previous_config:sub(2)
    package.loaded["luainstaller.windows_host"] = {call=function(operation, target)
        if operation == "pid" then return true, "123" end
        if operation == "identity" then
            return true, "fixture-machine\n" .. (tostring(target) == "123"
                and "0000000000000001" or "0000000000000002")
        end
        if operation == "alive" then
            if state == "unknown" then return false, "fixture access denied" end
            return true, state
        end
        error("unexpected process query: " .. operation)
    end}
    local called, failure = pcall(function()
        local simulated = assert(loadfile("src/lock_owner.lua"))()
        local identity = "windows:" .. require("luainstaller.hash").sha256("fixture-machine")
            .. ":0000000000000002"
        assert(simulated.isAlive("456", identity) == false, "exited Windows identity was treated as alive")
        state = "yes"
        assert(simulated.isAlive("456", identity) == true, "live Windows identity was treated as dead")
        state = "unknown"
        assert(simulated.isAlive("456", identity) == nil, "unknown Windows liveness was treated as dead")
    end)
    package.config = previous_config
    package.loaded["luainstaller.windows_host"] = previous_host
    assert(called, failure)
end
print("lock process identity ok")
