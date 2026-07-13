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
local BASE64_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function commandSucceeded(status)
    return status == true or status == 0
end

local function execute(command)
    local called, first = pcall(os.execute, command)
    return called and commandSucceeded(first)
end

local function base64Encode(value)
    local output = {}
    for index = 1, #value, 3 do
        local first = value:byte(index)
        local second = value:byte(index + 1)
        local third = value:byte(index + 2)
        local packed = (first << 16) | ((second or 0) << 8) | (third or 0)
        output[#output + 1] = BASE64_ALPHABET:sub(((packed >> 18) & 63) + 1,
            ((packed >> 18) & 63) + 1)
        output[#output + 1] = BASE64_ALPHABET:sub(((packed >> 12) & 63) + 1,
            ((packed >> 12) & 63) + 1)
        output[#output + 1] = second
            and BASE64_ALPHABET:sub(((packed >> 6) & 63) + 1, ((packed >> 6) & 63) + 1)
            or "="
        output[#output + 1] = third
            and BASE64_ALPHABET:sub((packed & 63) + 1, (packed & 63) + 1)
            or "="
    end
    return table.concat(output)
end

local function windowsPathExpression(path)
    if type(path) ~= "string" or path == "" or path:find("\0", 1, true) then
        return nil
    end
    return "[Text.Encoding]::Default.GetString([Convert]::FromBase64String('"
        .. base64Encode(path) .. "'))"
end

local function windowsPowerShellCommand(script)
    local powershell = process.windowsPowerShellPath()
    if not powershell then
        return nil
    end
    return 'call "' .. powershell .. '" -NoProfile -NonInteractive -Command "'
        .. script .. '"'
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
        local expression = windowsPathExpression(path)
        if not expression then return true end
        local command = windowsPowerShellCommand(string.format(
            "$p=%s;$i=Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue;"
                .. "if ($null -eq $i) { exit 0 };"
                .. "if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 };"
                .. "exit 0",
            expression
        ))
        local safe = command and execute(command .. " >NUL 2>&1")
        -- Treat an unavailable/failed inspection as unsafe instead of
        -- silently accepting a junction or other reparse point.
        return not safe
    end
    return execute("test -L " .. process.shellQuote(path))
end

local function pathExists(path)
    if IS_WINDOWS then
        local expression = windowsPathExpression(path)
        if not expression then return false end
        local command = windowsPowerShellCommand(
            "$p=" .. expression
                .. ";$i=Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue;"
                .. "if ($null -eq $i) { exit 1 };exit 0"
        )
        return command and execute(command .. " >NUL 2>&1") or false
    end
    return execute("test -e " .. process.shellQuote(path)) or isSymbolicLink(path)
end

local function isDirectory(path)
    if IS_WINDOWS then
        local expression = windowsPathExpression(path)
        if not expression then return false end
        local command = windowsPowerShellCommand(string.format(
            "$p=%s;$i=Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue;"
                .. "if ($null -eq $i) { exit 1 };"
                .. "if (-not ($i -is [IO.DirectoryInfo])) { exit 1 };"
                .. "if ($i.Attributes -band [IO.FileAttributes]::ReparsePoint) { exit 1 };"
                .. "exit 0",
            expression
        ))
        return command and execute(command .. " >NUL 2>&1") or false
    end
    return not isSymbolicLink(path) and execute("test -d " .. process.shellQuote(path))
end

local function isRegularFile(path)
    if IS_WINDOWS then
        return fs.isRegularFile(path)
    end
    if isSymbolicLink(path) then
        return false
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
        local expression = windowsPathExpression(path)
        if not expression then return false end
        local command = windowsPowerShellCommand(table.concat({
            "$p=", expression, ";try {",
            "$full=[IO.Path]::GetFullPath($p);",
            "$root=[IO.Path]::GetPathRoot($full);",
            "if ([string]::IsNullOrEmpty($root)) { exit 1 };",
            "$current=$root;$relative=$full.Substring($root.Length);",
            "foreach ($part in ($relative -split '[\\\\/]')) {",
            "if ([string]::IsNullOrEmpty($part)) { continue };",
            "$current=Join-Path $current $part;",
            "if (Test-Path -LiteralPath $current) {",
            "$item=Get-Item -LiteralPath $current -Force -ErrorAction Stop;",
            "if (-not ($item -is [IO.DirectoryInfo]) -or ",
            "($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { exit 1 }",
            "} else { break }",
            "};",
            "$null=[IO.Directory]::CreateDirectory($full);",
            "$final=Get-Item -LiteralPath $full -Force -ErrorAction Stop;",
            "if (-not ($final -is [IO.DirectoryInfo]) -or ",
            "($final.Attributes -band [IO.FileAttributes]::ReparsePoint)) { exit 1 };",
            "exit 0 } catch { exit 1 }",
        }))
        return command and execute(command .. " >NUL 2>&1") or false
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
        local expression = windowsPathExpression(path)
        if not expression then return false end
        local command = windowsPowerShellCommand(
            "$p=" .. expression
                .. ";$ErrorActionPreference='Stop';"
                .. "try {$null=New-Item -Path $p -ItemType Directory;exit 0}"
                .. "catch {exit 1}"
        )
        return command and execute(command .. " >NUL 2>&1") or false
    end
    return execute("mkdir -m 700 " .. process.shellQuote(path) .. " 2>/dev/null")
end

local function removeDirectory(path)
    if IS_WINDOWS then
        local expression = windowsPathExpression(path)
        if not expression then return false end
        local command = windowsPowerShellCommand(
            "$p=" .. expression
                .. ";try {$i=Get-Item -LiteralPath $p -Force -ErrorAction Stop;"
                .. "if (-not ($i -is [IO.DirectoryInfo]) -or "
                .. "($i.Attributes -band [IO.FileAttributes]::ReparsePoint)) {exit 1};"
                .. "[IO.Directory]::Delete($p,$false);exit 0}catch{exit 1}"
        )
        return command and execute(command .. " >NUL 2>&1") or false
    end
    return execute("rmdir " .. process.shellQuote(path) .. " 2>/dev/null")
end

local function getProcessId()
    if cached_process_id then
        return cached_process_id
    end
    local value
    if IS_WINDOWS then
        local command = windowsPowerShellCommand("[Console]::Write($PID)")
        value = command and process.firstLine(command) or nil
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
        local expression = windowsPathExpression(path)
        if not expression then return nil end
        local command = windowsPowerShellCommand(string.format(
            "$p=%s;$i=Get-Item -LiteralPath $p -Force -ErrorAction Stop;"
                .. "$d=[DateTimeOffset]$i.LastWriteTimeUtc;"
                .. "[Console]::Write($d.ToUnixTimeSeconds())",
            expression
        ))
        line = command and process.firstLine(command) or nil
    else
        local quoted = process.shellQuote(path)
        line = process.firstLine("stat -c %Y " .. quoted .. " 2>/dev/null")
        if not tonumber(line) then
            line = process.firstLine("stat -f %m " .. quoted .. " 2>/dev/null")
        end
    end
    return tonumber(line)
end

local function directoryIdentity(path)
    if IS_WINDOWS then
        return nil
    end
    local quoted = process.shellQuote(path)
    local identity = process.firstLine("stat -c '%d:%i' " .. quoted .. " 2>/dev/null")
    if not tostring(identity or ""):match("^%d+:%d+$") then
        identity = process.firstLine("stat -f '%d:%i' " .. quoted .. " 2>/dev/null")
    end
    if tostring(identity or ""):match("^%d+:%d+$") then
        return identity
    end
    return nil
end

local function singleOwnerSentinel(lock_path)
    local ok, output
    if IS_WINDOWS then
        local expression = windowsPathExpression(lock_path)
        if not expression then return nil end
        local command = windowsPowerShellCommand(
            "$p=" .. expression
                .. ";Get-ChildItem -LiteralPath $p -Force -File -Filter 'owner.*' "
                .. "-ErrorAction SilentlyContinue | ForEach-Object {$_.Name}"
        )
        if command then
            ok, output = process.output(command)
        else
            ok, output = false, nil
        end
    else
        ok, output = process.output("cd " .. process.shellQuote(lock_path)
            .. " 2>/dev/null && for item in owner.*; do "
            .. "test -f \"$item\" && printf '%s\\n' \"$item\"; done")
    end
    if not ok and (not output or output == "") then
        return nil
    end
    local found
    for name in tostring(output or ""):gmatch("[^\r\n]+") do
        local token = name:match("^owner%.([%w_.-]+)$")
        if not token or found then
            return nil
        end
        found = {
            token = token,
            path = lock_path .. PATH_SEP .. name,
        }
    end
    if not found or not isRegularFile(found.path) then
        return nil
    end
    return found
end

local function lockCreatedAt(lock_path)
    local initial_identity = directoryIdentity(lock_path)
    local function observed(kind, content, token)
        local created = select(1, parseOwner(content))
        if initial_identity and directoryIdentity(lock_path) ~= initial_identity then
            return nil, nil
        end
        return created, {
            kind = kind,
            content = content,
            token = token,
            identity = initial_identity,
        }
    end
    local owner_path = lock_path .. PATH_SEP .. "owner"
    if isRegularFile(owner_path) then
        local content = fs.readFile(owner_path)
        local created, token = parseOwner(content)
        if created then
            return observed("legacy", content, token)
        end
    end
    local sentinel = singleOwnerSentinel(lock_path)
    if sentinel then
        local content = fs.readFile(sentinel.path)
        local created, token = parseOwner(content)
        if created and token == sentinel.token then
            return observed("sentinel", content, token)
        end
    end
    local modified = directoryModifiedAt(lock_path)
    if initial_identity and directoryIdentity(lock_path) == initial_identity then
        return modified, {
            kind = "unowned",
            identity = initial_identity,
        }
    end
    return modified, nil
end

local function restoreMovedLock(release_path, lock_path)
    if pathExists(lock_path) or isSymbolicLink(lock_path) then
        return false
    end
    if IS_WINDOWS then
        -- Windows directory rename does not replace a destination that appears
        -- in this window, so a best-effort restore is no-clobber there.
        return os.rename(release_path, lock_path) and true or false
    end
    -- Reserve the public name first.  POSIX rename then replaces only this
    -- empty directory atomically, so a newly acquired lock cannot appear in
    -- the check-to-restore window.
    if not createDirectory(lock_path) then
        return false
    end
    return os.rename(release_path, lock_path) and true or false
end

local function removeOwnedLock(lock_path, token, release_token, expected_content)
    local release_path = lock_path .. ".release." .. release_token
    if pathExists(release_path) or isSymbolicLink(release_path)
        or not os.rename(lock_path, release_path) then
        return false
    end
    local sentinel_path = release_path .. PATH_SEP .. "owner." .. token
    local content = fs.readFile(sentinel_path)
    local _, current_token = parseOwner(content)
    if current_token ~= token or content ~= expected_content then
        restoreMovedLock(release_path, lock_path)
        return false
    end
    if not os.remove(sentinel_path) then
        return false
    end
    return removeDirectory(release_path)
end

local function abandonPartiallyCreatedLock(lock_path, token, release_token, expected_content)
    local release_path = lock_path .. ".release." .. release_token
    if pathExists(release_path) or isSymbolicLink(release_path)
        or not os.rename(lock_path, release_path) then
        return false
    end
    local sentinel_path = release_path .. PATH_SEP .. "owner." .. token
    local content = fs.readFile(sentinel_path)
    if content == nil and removeDirectory(release_path) then
        return true
    end
    if content ~= expected_content then
        restoreMovedLock(release_path, lock_path)
        return false
    end
    if not os.remove(sentinel_path) then
        return false
    end
    return removeDirectory(release_path)
end

local function recoverStaleLock(lock_path)
    if isSymbolicLink(lock_path) or not isDirectory(lock_path) then
        return false
    end
    local created, observed = lockCreatedAt(lock_path)
    if not created or created > os.time() - LOCK_STALE_SECONDS then
        return false
    end
    -- Owner-less recovery is safe only when the platform supplies a stable
    -- directory identity that can be checked after the rename.
    if not observed then
        return false
    end

    local tombstone = lock_path .. ".stale." .. uniqueToken()
    if not os.rename(lock_path, tombstone) then
        return false
    end

    if observed.kind == "unowned" then
        if directoryIdentity(tombstone) == observed.identity
            and removeDirectory(tombstone) then
            return true
        end
        restoreMovedLock(tombstone, lock_path)
        return false
    end

    local verified = observed.identity == nil
        or directoryIdentity(tombstone) == observed.identity
    local owner_path = tombstone .. PATH_SEP .. "owner"
    if observed.kind == "legacy" then
        verified = verified and isRegularFile(owner_path)
            and fs.readFile(owner_path) == observed.content
    else
        local sentinel = singleOwnerSentinel(tombstone)
        verified = verified and sentinel ~= nil
            and sentinel.token == observed.token
            and fs.readFile(sentinel.path) == observed.content
    end
    if not verified then
        restoreMovedLock(tombstone, lock_path)
        return false
    end

    local stale_owner_path = observed.kind == "legacy"
        and owner_path
        or tombstone .. PATH_SEP .. "owner." .. observed.token
    if not os.remove(stale_owner_path) then
        return false
    end
    return removeDirectory(tombstone)
end

local function waitForLockRetry()
    if IS_WINDOWS then
        local command = windowsPowerShellCommand(string.format(
            "Start-Sleep -Milliseconds %d",
            math.floor(LOCK_RETRY_SECONDS * 1000)
        ))
        if command then execute(command) end
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
            local release_token = uniqueToken()
            local content = ownerContent(token)
            local sentinel_path = lock_path .. PATH_SEP .. "owner." .. token
            local sentinel_ok = fs.writeFile(sentinel_path, content)
            local permissions_ok = sentinel_ok and chmodPath(sentinel_path, 600)
            if permissions_ok then
                return lock_path, token, release_token, content
            end
            abandonPartiallyCreatedLock(lock_path, token, release_token, content)
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
    local lock_path, token, release_token, owner_content = acquireLock()
    if not lock_path then
        return false
    end
    local packed = table.pack(pcall(callback, token))
    local released = removeOwnedLock(lock_path, token, release_token, owner_content)
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
