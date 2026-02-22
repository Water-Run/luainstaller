--[[
Centralized logging system for luainstaller.
Provides persistent file-based log storage with query
and filtering capabilities. Logs are serialized as Lua
tables and stored under the user home directory.

Author:
    WaterRun
File:
    logger.lua
Date:
    2026-02-22
Updated:
    2026-02-22
]]


--[[
Log level enumeration.

Enum:
    LogLevel
Values:
    DEBUG: Diagnostic tracing information
    INFO: General operational information
    WARNING: Non-fatal anomaly notification
    ERROR: Operation failure notification
    SUCCESS: Successful operation notification
]]
local LogLevel = {
    DEBUG   = "debug",
    INFO    = "info",
    WARNING = "warning",
    ERROR   = "error",
    SUCCESS = "success",
}


--@description: Maximum number of log entries retained in storage
--@const: MAX_LOGS
local MAX_LOGS = 1000


--@description: Path separator for the current platform
--@const: PATH_SEP
local PATH_SEP = package.config:sub(1, 1)


--@description: True when running on Windows
--@const: IS_WINDOWS
local IS_WINDOWS = (PATH_SEP == "\\")


--@description: Cached resolved log file path
--@local: true
local cached_log_file_path = nil


--@description: Determine the log storage directory under the user home
--@local: true
--@return: string - Absolute path to the log storage directory
local function getLogDirectory()
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or "."
    return home .. PATH_SEP .. ".luainstaller"
end


--@description: Ensure a directory exists by invoking the platform mkdir command
--@local: true
--@param path: string - Directory path to create
local function ensureDirectory(path)
    if IS_WINDOWS then
        os.execute(string.format('if not exist "%s" mkdir "%s"', path, path))
    else
        os.execute(string.format('mkdir -p "%s" 2>/dev/null', path))
    end
end


--@description: Resolve and cache the log file path
--@local: true
--@return: string - Absolute path to the log file
local function getLogFilePath()
    if cached_log_file_path then
        return cached_log_file_path
    end
    local dir = getLogDirectory()
    cached_log_file_path = dir .. PATH_SEP .. "logs.lua"
    return cached_log_file_path
end


--@description: Serialize a Lua value into valid Lua source text
--@local: true
--@param val: any - Value to serialize (string, number, boolean, nil, table)
--@param indent: number - Current indentation depth
--@return: string - Lua source representation of the value
local function serializeValue(val, indent)
    indent = indent or 0
    local val_type = type(val)

    if val_type == "string" then
        return string.format("%q", val)
    elseif val_type == "number" then
        return tostring(val)
    elseif val_type == "boolean" then
        return tostring(val)
    elseif val_type == "nil" then
        return "nil"
    elseif val_type == "table" then
        local parts = {}
        local pad = string.rep("    ", indent + 1)
        local closing_pad = string.rep("    ", indent)

        local is_sequence = true
        local max_idx = 0
        for k, _ in pairs(val) do
            if type(k) ~= "number" or k ~= math.floor(k) or k < 1 then
                is_sequence = false
                break
            end
            if k > max_idx then
                max_idx = k
            end
        end
        if is_sequence and max_idx == #val then
            for i = 1, #val do
                parts[#parts + 1] = pad .. serializeValue(val[i], indent + 1)
            end
        else
            for k, v in pairs(val) do
                local key_repr
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    key_repr = k
                else
                    key_repr = "[" .. serializeValue(k, indent + 1) .. "]"
                end
                parts[#parts + 1] = pad .. key_repr .. " = " .. serializeValue(v, indent + 1)
            end
        end

        if #parts == 0 then
            return "{}"
        end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. closing_pad .. "}"
    end

    return "nil"
end


--@description: Load the log table from the persistent file
--@local: true
--@return: table - List of log entry tables, empty table on failure
local function loadFromFile()
    local path = getLogFilePath()
    local chunk = loadfile(path, "t", {})
    if not chunk then
        return {}
    end
    local ok, data = pcall(chunk)
    if not ok or type(data) ~= "table" then
        return {}
    end
    return data
end


--@description: Persist the log table to the storage file
--@local: true
--@param logs: table - List of log entry tables
--@return: boolean - True when the write succeeds
local function saveToFile(logs)
    ensureDirectory(getLogDirectory())
    local path = getLogFilePath()
    local handle = io.open(path, "w")
    if not handle then
        return false
    end
    handle:write("return ")
    handle:write(serializeValue(logs))
    handle:write("\n")
    handle:close()
    return true
end


--@description: Produce an ISO-8601 UTC timestamp string
--@local: true
--@return: string - Timestamp in the form YYYY-MM-DDTHH:MM:SSZ
local function getTimestamp()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end


--[[
Public module interface for the logging system.

Author:
    WaterRun
Module:
    logger
]]
local M = {}

M.LogLevel = LogLevel


--@description: Record a log entry to persistent storage
--@param level: string - Log level value from LogLevel
--@param source: string - Originating subsystem (cli, api, analyzer)
--@param action: string - Operation name (build, analyze, logs)
--@param message: string - Human-readable description
--@param details: table|nil - Optional key-value detail pairs
function M.log(level, source, action, message, details)
    local entry = {
        timestamp = getTimestamp(),
        level     = level,
        source    = source,
        action    = action,
        message   = message,
        details   = details or {},
    }

    local ok, logs = pcall(loadFromFile)
    if not ok or type(logs) ~= "table" then
        logs = {}
    end

    logs[#logs + 1] = entry

    if #logs > MAX_LOGS then
        local trimmed = {}
        local start_idx = #logs - MAX_LOGS + 1
        for i = start_idx, #logs do
            trimmed[#trimmed + 1] = logs[i]
        end
        logs = trimmed
    end

    pcall(saveToFile, logs)
end

--@description: Convenience wrapper to log an error entry
--@param source: string - Originating subsystem
--@param action: string - Operation name
--@param message: string - Error description
--@param details: table|nil - Optional details
function M.logError(source, action, message, details)
    M.log(LogLevel.ERROR, source, action, message, details)
end

--@description: Convenience wrapper to log a success entry
--@param source: string - Originating subsystem
--@param action: string - Operation name
--@param message: string - Success description
--@param details: table|nil - Optional details
function M.logSuccess(source, action, message, details)
    M.log(LogLevel.SUCCESS, source, action, message, details)
end

--@description: Convenience wrapper to log an informational entry
--@param source: string - Originating subsystem
--@param action: string - Operation name
--@param message: string - Information text
--@param details: table|nil - Optional details
function M.logInfo(source, action, message, details)
    M.log(LogLevel.INFO, source, action, message, details)
end

--@description: Convenience wrapper to log a warning entry
--@param source: string - Originating subsystem
--@param action: string - Operation name
--@param message: string - Warning text
--@param details: table|nil - Optional details
function M.logWarning(source, action, message, details)
    M.log(LogLevel.WARNING, source, action, message, details)
end

--@description: Retrieve log entries with optional filtering and ordering
--@param opts: table|nil - Query options (limit: number|nil, level: string|nil, source: string|nil, action: string|nil, descending: boolean|nil)
--@return: table - Filtered and ordered list of log entry tables
function M.getLogs(opts)
    opts = opts or {}

    local ok, logs = pcall(loadFromFile)
    if not ok or type(logs) ~= "table" then
        return {}
    end

    if opts.level then
        local filtered = {}
        for i = 1, #logs do
            if logs[i].level == opts.level then
                filtered[#filtered + 1] = logs[i]
            end
        end
        logs = filtered
    end

    if opts.source then
        local filtered = {}
        for i = 1, #logs do
            if logs[i].source == opts.source then
                filtered[#filtered + 1] = logs[i]
            end
        end
        logs = filtered
    end

    if opts.action then
        local filtered = {}
        for i = 1, #logs do
            if logs[i].action == opts.action then
                filtered[#filtered + 1] = logs[i]
            end
        end
        logs = filtered
    end

    if opts.descending ~= false then
        table.sort(logs, function(a, b)
            return (a.timestamp or "") > (b.timestamp or "")
        end)
    else
        table.sort(logs, function(a, b)
            return (a.timestamp or "") < (b.timestamp or "")
        end)
    end

    if opts.limit and opts.limit > 0 and #logs > opts.limit then
        local limited = {}
        for i = 1, opts.limit do
            limited[i] = logs[i]
        end
        logs = limited
    end

    return logs
end

--@description: Remove all stored log entries
--@return: boolean - True when the clear operation succeeds
function M.clearLogs()
    local ok = pcall(saveToFile, {})
    return ok == true
end

return M
