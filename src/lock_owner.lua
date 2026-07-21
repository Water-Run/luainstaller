--[[
Ownership records and process-liveness helpers for crash-safe locks.

Author:
    WaterRun
File:
    lock_owner.lua
Date:
    2026-07-18
Updated:
    2026-07-18
]]

local hash = require("luainstaller.hash")
local process = require("luainstaller.process")

local M = {}
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local cached_process_id

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

local function windowsParentProcessId()
    local script = table.concat({
        "$Current=[int]$PID;",
        "$Shells=@('powershell.exe','pwsh.exe','cmd.exe');",
        "$Found=0;",
        "for($i=0;$i -lt 8;$i++){",
        "$P=Get-WmiObject Win32_Process -Filter ('ProcessId='+$Current) -ErrorAction SilentlyContinue;",
        "if($null -eq $P){break};",
        "$ParentId=[int]$P.ParentProcessId;if($ParentId -le 0){break};",
        "$Parent=Get-WmiObject Win32_Process -Filter ('ProcessId='+$ParentId) -ErrorAction SilentlyContinue;",
        "if($null -eq $Parent){break};",
        "if($Shells -notcontains ([string]$Parent.Name).ToLowerInvariant())",
        "{$Found=$ParentId;break};",
        "$Current=$ParentId",
        "};",
        "if($Found -le 0){exit 1};[Console]::Write($Found)",
    })
    local ok, output = process.outputPowerShell(script)
    if not ok then return nil, tostring(output) end
    local pid = tostring(output or ""):match("(%d+)")
    if not validInteger(pid) then return nil, "cannot identify the owning Windows process" end
    return pid
end

function M.currentPid()
    if cached_process_id then return cached_process_id end
    local pid, err
    if IS_WINDOWS then
        pid, err = windowsParentProcessId()
    else
        pid = process.firstLine([[printf '%s' "$PPID"]])
        if not validInteger(pid) then
            err = "cannot identify the owning POSIX process"
            pid = nil
        end
    end
    if not pid then return nil, err end
    cached_process_id = pid
    return cached_process_id
end

function M.secureToken(context)
    local random_bytes
    if IS_WINDOWS then
        local ok, output = process.outputPowerShell(table.concat({
            "$Bytes=New-Object byte[] 32;",
            "$Rng=[Security.Cryptography.RandomNumberGenerator]::Create();",
            "try{$Rng.GetBytes($Bytes)}finally{$Rng.Dispose()};",
            "[Console]::Write([Convert]::ToBase64String($Bytes))",
        }))
        if not ok or not tostring(output):match("^[A-Za-z0-9+/]+=?=?%s*$") then
            return nil, tostring(output or "cannot acquire Windows cryptographic randomness")
        end
        random_bytes = tostring(output):gsub("%s+$", "")
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
    local lines = {
        "version=1",
        "token=" .. owner.token,
        "pid=" .. pid,
        "created=" .. created,
    }
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
            and key ~= "created" and key ~= "output" and key ~= "staging" then
            return nil, "lock owner record contains an unknown field"
        end
        fields[key] = value
    end
    if fields.version ~= "1" or not validToken(fields.token)
        or not validInteger(fields.pid) or not validInteger(fields.created) then
        return nil, "lock owner record is invalid"
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
end

function M.isAlive(pid)
    pid = validInteger(pid)
    if not pid then return nil, "process id is invalid" end
    if IS_WINDOWS then
        local ok, output = process.outputPowerShell(
            "$P=Get-Process -Id " .. pid
                .. " -ErrorAction SilentlyContinue;if($null -eq $P){exit 1}"
        )
        if ok then return true end
        if tostring(output or ""):match("[Aa]ccess.+[Dd]enied") then
            return nil, tostring(output)
        end
        return false
    end
    local ok, output = process.outputCommand("kill", { "-0", pid })
    if ok then return true end
    output = tostring(output or "")
    if output:lower():find("operation not permitted", 1, true)
        or output:lower():find("permission denied", 1, true) then
        return nil, output
    end
    return false
end

return M
