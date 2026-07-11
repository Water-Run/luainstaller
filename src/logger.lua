--[[
Concurrent, crash-safe logging for luainstaller.

Author:
    WaterRun
File:
    logger.lua
Date:
    2026-02-22
Updated:
    2026-07-11
]]

local fs = require("luainstaller.fs")
local process = require("luainstaller.process")

local LogLevel = {
    DEBUG   = "debug",
    INFO    = "info",
    WARNING = "warning",
    ERROR   = "error",
    SUCCESS = "success",
}

local MAX_LOGS = 1000
local LOCK_TIMEOUT_SECONDS = 5
local LOCK_STALE_SECONDS = 120
local LOCK_RETRY_SECONDS = 0.05
local MAX_SERIALIZE_DEPTH = 64

local PATH_SEP = package.config:sub(1, 1)
local IS_WINDOWS = PATH_SEP == "\\"
local cached_log_file_path = nil
local cached_process_id = nil
local token_counter = 0

local function commandSucceeded(status)
    return status == true or status == 0
end

local function execute(command)
    local called, first = pcall(os.execute, command)
    return called and commandSucceeded(first)
end

local function windowsCommandPathIsSafe(path)
    return type(path) == "string"
        and path ~= ""
        and not path:find('[%z\r\n"&|<>^%%!]')
end

local function getLogDirectory()
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
    return home .. PATH_SEP .. ".luainstaller"
end

local function getLogFilePath()
    if not cached_log_file_path then
        cached_log_file_path = getLogDirectory() .. PATH_SEP .. "logs.lua"
    end
    return cached_log_file_path
end

local function isSymbolicLink(path)
    if IS_WINDOWS then
        if not windowsCommandPathIsSafe(path) then
            return true
        end
        local powershell_path = path:gsub("'", "''")
        local safe = execute(string.format(
            'powershell -NoProfile -NonInteractive -Command "$i=Get-Item -LiteralPath \'%s\' -ErrorAction SilentlyContinue;if ($null -eq $i) { exit 0 };if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 };exit 0" >NUL 2>&1',
            powershell_path
        ))
        -- Treat an unavailable/failed inspection as unsafe instead of
        -- silently accepting a junction or other reparse point.
        return not safe
    end
    return execute("test -L " .. process.shellQuote(path))
end

local function pathExists(path)
    if IS_WINDOWS then
        if not windowsCommandPathIsSafe(path) then
            return false
        end
        return execute(string.format('if exist "%s" (exit /b 0) else (exit /b 1)', path))
    end
    return execute("test -e " .. process.shellQuote(path)) or isSymbolicLink(path)
end

local function isDirectory(path)
    if IS_WINDOWS then
        if not windowsCommandPathIsSafe(path) then
            return false
        end
        return execute(string.format('if exist "%s\\NUL" (exit /b 0) else (exit /b 1)', path))
    end
    return not isSymbolicLink(path) and execute("test -d " .. process.shellQuote(path))
end

local function isRegularFile(path)
    if isSymbolicLink(path) then
        return false
    end
    if IS_WINDOWS then
        local content = fs.readFile(path)
        return content ~= nil
    end
    return execute("test -f " .. process.shellQuote(path))
end

local function chmodPath(path, mode)
    if IS_WINDOWS then
        return true
    end
    return execute("chmod " .. tostring(mode) .. " " .. process.shellQuote(path) .. " 2>/dev/null")
end

local function ensureDirectory(path)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
        return false
    end
    if IS_WINDOWS then
        if not windowsCommandPathIsSafe(path) then
            return false
        end
        if isSymbolicLink(path) then
            return false
        end
        local created = execute(string.format('if not exist "%s" mkdir "%s"', path, path))
        return created and isDirectory(path) and not isSymbolicLink(path)
    end

    local quoted = process.shellQuote(path)
    return execute(table.concat({
        "test ! -L " .. quoted,
        "mkdir -p -m 700 " .. quoted .. " 2>/dev/null",
        "test -d " .. quoted,
        "test ! -L " .. quoted,
        "test \"$(LC_ALL=C ls -dn " .. quoted .. " | awk '{ print $3 }')\" = \"$(id -u)\"",
        "chmod 700 " .. quoted .. " 2>/dev/null",
    }, " && "))
end

local function createDirectory(path)
    if IS_WINDOWS then
        if not windowsCommandPathIsSafe(path) then
            return false
        end
        return execute(string.format('mkdir "%s" >NUL 2>&1', path))
    end
    return execute("mkdir -m 700 " .. process.shellQuote(path) .. " 2>/dev/null")
end

local function removeDirectory(path)
    if IS_WINDOWS then
        if not windowsCommandPathIsSafe(path) then
            return false
        end
        return execute(string.format('rmdir "%s" >NUL 2>&1', path))
    end
    return execute("rmdir " .. process.shellQuote(path) .. " 2>/dev/null")
end

local function getProcessId()
    if cached_process_id then
        return cached_process_id
    end
    local value
    if IS_WINDOWS then
        value = process.firstLine(
            'powershell -NoProfile -NonInteractive -Command "[Console]::Write($PID)"'
        )
    else
        value = process.firstLine([[printf '%s\n' "$PPID"]])
    end
    cached_process_id = tostring(value or "unknown"):gsub("[^%w_-]", "")
    return cached_process_id
end

local function uniqueToken()
    token_counter = token_counter + 1
    local address = tostring({}):gsub("[^%w]", "")
    return table.concat({
        tostring(os.time()),
        getProcessId(),
        tostring(math.floor(os.clock() * 1000000000)),
        tostring(token_counter),
        address,
    }, "-")
end

local function ownerContent(token, created)
    return string.format("created=%d\ntoken=%s\n", created or os.time(), token)
end

local function parseOwner(content)
    if type(content) ~= "string" then
        return nil, nil
    end
    local created, token = content:match("^created=(%d+)\ntoken=([%w_.-]+)\n$")
    if not created then
        return nil, nil
    end
    return tonumber(created), token
end

local function directoryModifiedAt(path)
    local line
    if IS_WINDOWS then
        if not windowsCommandPathIsSafe(path) then
            return nil
        end
        local powershell_path = path:gsub("'", "''")
        line = process.firstLine(string.format(
            'powershell -NoProfile -NonInteractive -Command "$i=Get-Item -LiteralPath \'%s\';$d=[DateTimeOffset]$i.LastWriteTimeUtc;[Console]::Write($d.ToUnixTimeSeconds())"',
            powershell_path
        ))
    else
        local quoted = process.shellQuote(path)
        line = process.firstLine("stat -c %Y " .. quoted .. " 2>/dev/null")
        if not tonumber(line) then
            line = process.firstLine("stat -f %m " .. quoted .. " 2>/dev/null")
        end
    end
    return tonumber(line)
end

local function lockCreatedAt(lock_path)
    local owner_path = lock_path .. PATH_SEP .. "owner"
    if isRegularFile(owner_path) then
        local content = fs.readFile(owner_path)
        local created = parseOwner(content)
        if created then
            return created
        end
    end
    return directoryModifiedAt(lock_path)
end

local function removeOwnedLock(lock_path, token)
    local owner_path = lock_path .. PATH_SEP .. "owner"
    local sentinel_path = lock_path .. PATH_SEP .. "owner." .. token
    local content = fs.readFile(owner_path)
    local _, current_token = parseOwner(content)
    if current_token ~= token then
        return false
    end
    if not os.remove(sentinel_path) then
        return false
    end

    content = fs.readFile(owner_path)
    _, current_token = parseOwner(content)
    if current_token ~= token then
        return false
    end
    if not os.remove(owner_path) then
        return false
    end
    return removeDirectory(lock_path)
end

local function abandonPartiallyCreatedLock(lock_path, token)
    os.remove(lock_path .. PATH_SEP .. "owner")
    os.remove(lock_path .. PATH_SEP .. "owner." .. token)
    removeDirectory(lock_path)
end

local function recoverStaleLock(lock_path)
    if isSymbolicLink(lock_path) or not isDirectory(lock_path) then
        return false
    end
    local created = lockCreatedAt(lock_path)
    if not created or created > os.time() - LOCK_STALE_SECONDS then
        return false
    end

    local tombstone = lock_path .. ".stale." .. uniqueToken()
    if not os.rename(lock_path, tombstone) then
        return false
    end

    local owner_path = tombstone .. PATH_SEP .. "owner"
    local content = isRegularFile(owner_path) and fs.readFile(owner_path) or nil
    local _, token = parseOwner(content)
    if token then
        os.remove(tombstone .. PATH_SEP .. "owner." .. token)
    end
    os.remove(owner_path)
    removeDirectory(tombstone)
    return true
end

local function waitForLockRetry()
    if IS_WINDOWS then
        execute(string.format(
            'powershell -NoProfile -NonInteractive -Command "Start-Sleep -Milliseconds %d"',
            math.floor(LOCK_RETRY_SECONDS * 1000)
        ))
    else
        execute("sleep " .. tostring(LOCK_RETRY_SECONDS))
    end
end

local function acquireLock()
    if not ensureDirectory(getLogDirectory()) then
        return nil, nil
    end
    local lock_path = getLogFilePath() .. ".lock"
    local max_attempts = math.max(1, math.floor(LOCK_TIMEOUT_SECONDS / LOCK_RETRY_SECONDS))

    for attempt = 0, max_attempts do
        if createDirectory(lock_path) then
            local token = uniqueToken()
            local content = ownerContent(token)
            local sentinel_path = lock_path .. PATH_SEP .. "owner." .. token
            local owner_path = lock_path .. PATH_SEP .. "owner"
            local sentinel_ok = fs.writeFile(sentinel_path, content)
            local owner_ok = sentinel_ok and fs.writeFile(owner_path, content)
            local permissions_ok = owner_ok
                and chmodPath(sentinel_path, 600)
                and chmodPath(owner_path, 600)
            if permissions_ok then
                return lock_path, token
            end
            abandonPartiallyCreatedLock(lock_path, token)
            return nil, nil
        end

        local inspected = attempt % math.max(1, math.floor(1 / LOCK_RETRY_SECONDS)) == 0
        if inspected and isSymbolicLink(lock_path) then
            return nil, nil
        end
        local recovered = inspected and recoverStaleLock(lock_path)
        if not recovered and attempt < max_attempts then
            waitForLockRetry()
        end
    end
    return nil, nil
end

local function withLock(callback)
    local lock_path, token = acquireLock()
    if not lock_path then
        return false
    end
    local packed = table.pack(pcall(callback, token))
    local released = removeOwnedLock(lock_path, token)
    if not packed[1] or not released then
        return false
    end
    return table.unpack(packed, 2, packed.n)
end

local function serializeValue(value, indent, seen)
    indent = indent or 0
    seen = seen or {}
    if indent > MAX_SERIALIZE_DEPTH then
        error("log value nesting exceeds the serialization limit")
    end

    local value_type = type(value)
    if value_type == "string" then
        return string.format("%q", value)
    elseif value_type == "number" then
        if value ~= value or value == math.huge or value == -math.huge then
            error("log values must not contain non-finite numbers")
        end
        return tostring(value)
    elseif value_type == "boolean" then
        return tostring(value)
    elseif value_type == "nil" then
        return "nil"
    elseif value_type ~= "table" then
        error("unsupported log value type: " .. value_type)
    end

    if seen[value] then
        error("log values must not contain table cycles")
    end
    seen[value] = true

    local count, max_index, sequence = 0, 0, true
    for key in pairs(value) do
        count = count + 1
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            sequence = false
        elseif key > max_index then
            max_index = key
        end
    end
    sequence = sequence and count == max_index

    local pad = string.rep("    ", indent + 1)
    local closing_pad = string.rep("    ", indent)
    local parts = {}
    if sequence then
        for index = 1, max_index do
            parts[#parts + 1] = pad .. serializeValue(value[index], indent + 1, seen)
        end
    else
        local fields = {}
        for key, field_value in pairs(value) do
            local key_type = type(key)
            if key_type ~= "string" and key_type ~= "number" and key_type ~= "boolean" then
                error("unsupported log table key type: " .. key_type)
            end
            local key_repr
            if key_type == "string" and key:match("^[%a_][%w_]*$") then
                key_repr = key
            else
                key_repr = "[" .. serializeValue(key, indent + 1, seen) .. "]"
            end
            fields[#fields + 1] = {
                order = key_type .. "\0" .. key_repr,
                text = pad .. key_repr .. " = " .. serializeValue(field_value, indent + 1, seen),
            }
        end
        table.sort(fields, function(left, right)
            return left.order < right.order
        end)
        for _, field in ipairs(fields) do
            parts[#parts + 1] = field.text
        end
    end

    seen[value] = nil
    if #parts == 0 then
        return "{}"
    end
    return "{\n" .. table.concat(parts, ",\n") .. "\n" .. closing_pad .. "}"
end

local function validateLogs(data)
    if type(data) ~= "table" then
        return false
    end
    local count, max_index = 0, 0
    for key in pairs(data) do
        if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
            return false
        end
        count = count + 1
        if key > max_index then
            max_index = key
        end
    end
    if count ~= max_index or max_index > MAX_LOGS then
        return false
    end
    for index = 1, max_index do
        local entry = data[index]
        if type(entry) ~= "table"
            or type(entry.timestamp) ~= "string"
            or type(entry.level) ~= "string"
            or type(entry.source) ~= "string"
            or type(entry.action) ~= "string"
            or type(entry.message) ~= "string"
            or type(entry.details) ~= "table" then
            return false
        end
    end
    return true
end

local function parseLogContent(content, chunk_name)
    if type(content) ~= "string" or not content:match("^return%s") then
        return nil
    end
    local chunk = load(content, chunk_name, "t", {})
    if not chunk then
        return nil
    end
    local ok, data = pcall(chunk)
    if not ok or not validateLogs(data) then
        return nil
    end
    return data
end

local function logFileState(path)
    if isSymbolicLink(path) then
        return { kind = "unsafe" }
    end
    local kind
    if IS_WINDOWS then
        if not pathExists(path) then
            kind = "missing"
        elseif isRegularFile(path) then
            kind = "regular"
        else
            kind = "unsafe"
        end
    else
        local quoted = process.shellQuote(path)
        local ok, output = process.output(table.concat({
            "if test -L " .. quoted .. "; then printf unsafe",
            "elif test -f " .. quoted .. "; then printf regular",
            "elif test -e " .. quoted .. "; then printf unsafe",
            "else printf missing",
            "fi",
        }, "; "))
        kind = ok and output:match("^(%a+)") or "unsafe"
    end
    if kind ~= "regular" then
        return { kind = kind }
    end
    local content = fs.readFile(path)
    if not content then
        return { kind = "unsafe" }
    end
    return {
        kind = "regular",
        content = content,
        logs = parseLogContent(content, "@" .. path),
    }
end

local function loadFromFile()
    local path = getLogFilePath()
    local primary = logFileState(path)
    if primary.kind == "regular" and primary.logs then
        return primary.logs
    end
    local backup = logFileState(path .. ".bak")
    if backup.kind == "regular" and backup.logs then
        return backup.logs
    end
    return {}
end

local function removeRegular(path, state)
    state = state or logFileState(path)
    if state.kind == "missing" then
        return true
    end
    if state.kind ~= "regular" then
        return false
    end
    return os.remove(path) and true or false
end

local function publishTemporary(path, temporary, primary, backup)
    local backup_path = path .. ".bak"
    if primary.kind == "unsafe" or backup.kind == "unsafe" then
        return false
    end

    if primary.kind == "missing" then
        return os.rename(temporary, path) and true or false
    end

    if not primary.logs and backup.kind == "regular" and backup.logs then
        if not removeRegular(path, primary) then
            return false
        end
        return os.rename(temporary, path) and true or false
    end

    if not removeRegular(backup_path, backup) then
        return false
    end
    if not os.rename(path, backup_path) then
        return false
    end
    if os.rename(temporary, path) then
        return true
    end

    os.rename(backup_path, path)
    return false
end

local function saveToFile(logs, token)
    local serialized_ok, serialized = pcall(serializeValue, logs)
    if not serialized_ok then
        return false
    end
    local payload = "return " .. serialized .. "\n"
    if not parseLogContent(payload, "@generated-logs.lua") then
        return false
    end

    local path = getLogFilePath()
    local temporary = path .. ".tmp." .. token
    local wrote = fs.writeFile(temporary, payload)
    if not wrote then
        os.remove(temporary)
        return false
    end
    if not chmodPath(temporary, 600) then
        os.remove(temporary)
        return false
    end

    local persisted = fs.readFile(temporary)
    if persisted ~= payload or not parseLogContent(persisted, "@" .. temporary) then
        os.remove(temporary)
        return false
    end

    local primary = logFileState(path)
    local backup = logFileState(path .. ".bak")
    if not publishTemporary(path, temporary, primary, backup) then
        os.remove(temporary)
        return false
    end
    return true
end

local function getTimestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local M = {}
M.LogLevel = LogLevel

function M.log(level, source, action, message, details)
    local entry = {
        timestamp = getTimestamp(),
        level = level,
        source = source,
        action = action,
        message = message,
        details = details or {},
    }

    return withLock(function(token)
        local logs = loadFromFile()
        logs[#logs + 1] = entry
        if #logs > MAX_LOGS then
            local trimmed = {}
            local start_index = #logs - MAX_LOGS + 1
            for index = start_index, #logs do
                trimmed[#trimmed + 1] = logs[index]
            end
            logs = trimmed
        end
        return saveToFile(logs, token)
    end)
end

function M.logError(source, action, message, details)
    return M.log(LogLevel.ERROR, source, action, message, details)
end

function M.logSuccess(source, action, message, details)
    return M.log(LogLevel.SUCCESS, source, action, message, details)
end

function M.logInfo(source, action, message, details)
    return M.log(LogLevel.INFO, source, action, message, details)
end

function M.logWarning(source, action, message, details)
    return M.log(LogLevel.WARNING, source, action, message, details)
end

function M.getLogs(opts)
    opts = opts or {}
    local ok, logs = pcall(loadFromFile)
    if not ok or type(logs) ~= "table" then
        return {}
    end

    for _, key in ipairs({ "level", "source", "action" }) do
        if opts[key] then
            local filtered = {}
            for index = 1, #logs do
                if logs[index][key] == opts[key] then
                    filtered[#filtered + 1] = logs[index]
                end
            end
            logs = filtered
        end
    end

    table.sort(logs, function(left, right)
        if opts.descending == false then
            return (left.timestamp or "") < (right.timestamp or "")
        end
        return (left.timestamp or "") > (right.timestamp or "")
    end)

    if type(opts.limit) == "number" and opts.limit > 0 and #logs > opts.limit then
        local limited = {}
        for index = 1, opts.limit do
            limited[index] = logs[index]
        end
        logs = limited
    end
    return logs
end

function M.clearLogs()
    return withLock(function(token)
        -- The first publication may rotate the previous primary into the
        -- recovery generation. A second checked publication makes both
        -- generations empty before a clear can be reported as successful.
        return saveToFile({}, token) and saveToFile({}, token)
    end)
end

return M
