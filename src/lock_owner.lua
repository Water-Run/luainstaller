--[[
Ownership records and process-liveness helpers for crash-safe locks.

Author:
    WaterRun
File:
    lock_owner.lua
Date:
    2026-07-18
Updated:
    2026-10-15
]]

local hash = require("luainstaller.hash")
local process = require("luainstaller.process")

local M = {}
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local cached_process_id
local cached_scope, cached_platform

local function validInteger(value)
    value = tostring(value or "")
    if not value:match("^%d+$") then return nil end
    local numeric = tonumber(value)
    if not numeric or numeric < 1 or numeric ~= math.floor(numeric) then return nil end
    return value
end

local function validToken(value)
    return type(value) == "string"
        and #value >= 16 and #value <= 128
        and value:match("^[A-Za-z0-9_.-]+$") ~= nil
end

local function validIdentity(value)
    if type(value) ~= "string" or #value > 220 then return nil end
    local platform, scope, birth = value:match("^([%w]+):([0-9a-f]+):([%w]+)$")
    return platform and #scope == 64 and #birth <= 128 and value or nil
end

local function readSmall(path)
    local opened, handle = pcall(io.open, path, "rb")
    if not opened or not handle then return nil end
    local read, value = pcall(function() return handle:read(4097) end)
    local close, closed = pcall(function() return handle:close() end)
    if not read or type(value) ~= "string" or #value > 4096 or not close or not closed then
        return nil
    end
    return value
end

local function procRecord(pid)
    local value = readSmall("/proc/" .. tostring(pid) .. "/stat")
    if not value then return nil end
    -- comm can contain spaces and parentheses; fields start after its last ')'.
    local number, tail = value:match("^(%d+) %(.+%) (.*)$")
    if not number then return nil end
    local fields = {}
    for field in tail:gmatch("%S+") do fields[#fields + 1] = field end
    if not fields[20] or not fields[20]:match("^%d+$") then return nil end
    return {pid=number, birth=fields[20], dead=fields[1] == "Z" or fields[1] == "X"}
end

local function processScope()
    if cached_scope then return cached_platform, cached_scope end
    if procRecord("self") then
        local boot = readSmall("/proc/sys/kernel/random/boot_id")
        -- Fixed host queries use the bounded cold shell path. Obtaining a log
        -- owner must not compile a process backend while holding the log lock.
        local ok, namespace = process.output("LC_ALL=C readlink /proc/self/ns/pid")
        namespace = tostring(namespace or ""):match("^(pid:%[%d+%])%s*$")
        if boot and ok and namespace then
            cached_platform, cached_scope = "linux", hash.sha256(boot .. "\0" .. namespace)
        end
    elseif not IS_WINDOWS then
        local boot_ok, boot = process.output("LC_ALL=C sysctl -n kern.boottime")
        local host_ok, hostname = process.output("LC_ALL=C uname -n")
        if boot_ok and host_ok and boot:find("sec", 1, true) and hostname ~= "" then
            cached_platform, cached_scope = "posix", hash.sha256(hostname .. "\0" .. boot)
        end
    end
    return cached_platform, cached_scope
end

local function processIdentity(pid)
    if IS_WINDOWS then
        local ok, output = require("luainstaller.windows_host").call("identity", tostring(pid))
        if not ok then return nil, output end
        local machine, birth = output:match("^([^\r\n]+)\n([0-9a-f]+)$")
        if not machine or #birth ~= 16 then return nil, "invalid Windows process identity" end
        return "windows:" .. hash.sha256(machine) .. ":" .. birth
    end
    local platform, scope = processScope()
    if platform == "linux" then
        local record = procRecord(pid)
        if not record then return nil, "cannot read process start identity" end
        return platform .. ":" .. scope .. ":" .. record.birth, nil, record.dead
    elseif platform == "posix" then
        local ok, output = process.output("LC_ALL=C ps -p " .. process.quote(pid) .. " -o lstart=")
        output = tostring(output or ""):match("^%s*(.-)%s*$")
        if ok and output ~= "" then return platform .. ":" .. scope .. ":" .. hash.sha256(output) end
    end
    return nil, "process start identity is unavailable on this host"
end

local function windowsParentProcessId()
    local ok, output = require("luainstaller.windows_host").call("pid")
    if not ok then return nil, output end
    return validInteger(output)
end

function M.currentPid()
    if cached_process_id then return cached_process_id end
    local pid, err
    if IS_WINDOWS then
        pid, err = windowsParentProcessId()
    else
        local own = procRecord("self")
        pid = own and own.pid or process.currentPid()
        if not validInteger(pid) then
            err = "cannot identify the owning POSIX process"
            pid = nil
        end
    end
    if not pid then return nil, err end
    cached_process_id = pid
    return cached_process_id
end

function M.currentIdentity()
    local pid, err = M.currentPid()
    if not pid then return nil, err end
    return processIdentity(pid)
end

function M.secureToken(context)
    local random_bytes
    if IS_WINDOWS then
        local ok, output = require("luainstaller.windows_host").call("random")
        if not ok or type(output) ~= "string" or #output ~= 32 then
            return nil, tostring(output or "cannot acquire Windows cryptographic randomness")
        end
        random_bytes = output
    else
        local opened, handle, open_err = pcall(io.open, "/dev/urandom", "rb")
        if not opened or not handle then
            return nil, tostring(open_err or handle or "cannot open /dev/urandom")
        end
        local read_called, bytes, read_err = pcall(handle.read, handle, 32)
        local close_called, closed, close_err = pcall(handle.close, handle)
        if not read_called or type(bytes) ~= "string" or #bytes ~= 32
            or not close_called or not closed then
            return nil, tostring(read_err or close_err or bytes or closed
                or "short read from /dev/urandom")
        end
        random_bytes = bytes
    end
    return hash.sha256(tostring(context or "") .. "\0" .. random_bytes)
end

function M.encode(owner)
    if type(owner) ~= "table" or not validToken(owner.token) then
        return nil, "lock owner token is invalid"
    end
    local pid = validInteger(owner.pid)
    local created = validInteger(owner.created)
    if not pid or not created then return nil, "lock owner process metadata is invalid" end
    if owner.identity ~= nil and not validIdentity(owner.identity) then
        return nil, "lock owner process identity is invalid"
    end
    local lines = {
        owner.identity and "version=2" or "version=1",
        "token=" .. owner.token,
        "pid=" .. pid,
        "created=" .. created,
    }
    if owner.identity then lines[#lines + 1] = "identity=" .. owner.identity end
    if owner.output_hash ~= nil or owner.staging ~= nil then
        if type(owner.output_hash) ~= "string"
            or not owner.output_hash:match("^[0-9a-f][0-9a-f]+$")
            or #owner.output_hash ~= 64 then
            return nil, "lock owner output hash is invalid"
        end
        if type(owner.staging) ~= "string" or #owner.staging > 240
            or not owner.staging:match("^[A-Za-z0-9_.-]+$") then
            return nil, "lock owner staging name is invalid"
        end
        lines[#lines + 1] = "output=" .. owner.output_hash
        lines[#lines + 1] = "staging=" .. owner.staging
    end
    lines[#lines + 1] = ""
    return table.concat(lines, "\n")
end

function M.decode(content)
    if type(content) ~= "string" or content:sub(-1) ~= "\n" then
        return nil, "lock owner record is not newline terminated"
    end
    local fields = {}
    for line in content:gmatch("([^\n]+)\n") do
        local key, value = line:match("^([a-z]+)=([^\r\n]+)$")
        if not key or fields[key] ~= nil then return nil, "lock owner record is malformed" end
        if key ~= "version" and key ~= "token" and key ~= "pid"
            and key ~= "created" and key ~= "identity" and key ~= "output" and key ~= "staging" then
            return nil, "lock owner record contains an unknown field"
        end
        fields[key] = value
    end
    if (fields.version ~= "1" and fields.version ~= "2") or not validToken(fields.token)
        or not validInteger(fields.pid) or not validInteger(fields.created) then
        return nil, "lock owner record is invalid"
    end
    if (fields.version == "2" and not validIdentity(fields.identity))
        or (fields.version == "1" and fields.identity ~= nil) then
        return nil, "lock owner process identity is invalid"
    end
    if (fields.output == nil) ~= (fields.staging == nil) then
        return nil, "lock owner record is incomplete"
    end
    if fields.output and (#fields.output ~= 64
        or not fields.output:match("^[0-9a-f][0-9a-f]+$")) then
        return nil, "lock owner output hash is invalid"
    end
    if fields.staging and (#fields.staging > 240
        or not fields.staging:match("^[A-Za-z0-9_.-]+$")) then
        return nil, "lock owner staging name is invalid"
    end
    local owner = {
        token = fields.token,
        pid = fields.pid,
        created = tonumber(fields.created),
        output_hash = fields.output,
        staging = fields.staging,
        identity = fields.identity,
    }
    local canonical = M.encode(owner)
    if canonical ~= content then return nil, "lock owner record is not canonical" end
    return owner
end

function M.same(left, right)
    return type(left) == "table" and type(right) == "table"
        and left.token == right.token
        and tostring(left.pid) == tostring(right.pid)
        and tonumber(left.created) == tonumber(right.created)
        and left.output_hash == right.output_hash
        and left.staging == right.staging
        and left.identity == right.identity
end

function M.isAlive(pid, identity)
    pid = validInteger(pid)
    if not pid then return nil, "process id is invalid" end
    if identity ~= nil then
        if not validIdentity(identity) then return nil, "process identity is invalid" end
        local own, own_err = M.currentIdentity()
        if not own then return nil, own_err end
        if own:match("^([^:]+:[^:]+):") ~= identity:match("^([^:]+:[^:]+):") then
            return nil, "owner belongs to a different host, boot or process namespace"
        end
        local current, identity_err, dead = processIdentity(pid)
        if current then
            if dead or current ~= identity then return false end
            -- A terminated Windows process retains its start identity while
            -- another handle keeps the process object alive. Identity alone
            -- is therefore not a liveness check on this host.
            if IS_WINDOWS then return M.isAlive(pid) end
            return true
        end
        local alive, alive_err = M.isAlive(pid)
        if alive == false then return false end
        return nil, identity_err or alive_err
    end
    if IS_WINDOWS then
        local ok, output = require("luainstaller.windows_host").call("alive", pid)
        if not ok then return nil, output end
        return output == "yes"
    end
    local ok, output = process.output("LC_ALL=C kill -0 " .. pid, {timeout_seconds=5})
    if ok then return true end
    output = tostring(output or "")
    if output:lower():find("operation not permitted", 1, true)
        or output:lower():find("permission denied", 1, true) then
        return nil, output
    end
    if output:lower():find("no such process", 1, true) then return false end
    return nil, output
end

return M
