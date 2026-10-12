--[[
Process identity prevents PID reuse from keeping a stale lock alive.

Author:
    WaterRun
File:
    lock_identity.lua
Date:
    2026-10-12
Updated:
    2026-10-12
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
print("lock process identity ok")
