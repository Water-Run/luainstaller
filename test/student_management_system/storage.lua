--[[
JSON storage for the student management system sample.

Author:
    WaterRun
File:
    storage.lua
Date:
    2026-06-12
Updated:
    2026-06-12
]]

local cjson = require("cjson")
local utils = require("utils")

local M = {}

local function empty_data()
    return {
        version = 1,
        next_id = 1,
        students = {},
    }
end

-- @description: Load JSON data from disk.
-- @param path: string - JSON file path.
-- @return: table - Data document.
function M.load(path)
    if not utils.file_exists(path) then
        return empty_data()
    end
    local content = assert(utils.read_file(path))
    if utils.trim(content) == "" then
        return empty_data()
    end
    local ok, data = pcall(cjson.decode, content)
    if not ok or type(data) ~= "table" then
        error("invalid JSON storage file: " .. tostring(path))
    end
    data.version = tonumber(data.version) or 1
    data.next_id = tonumber(data.next_id) or 1
    data.students = type(data.students) == "table" and data.students or {}
    return data
end

-- @description: Save JSON data to disk through a temporary file.
-- @param path: string - JSON file path.
-- @param data: table - Data document.
function M.save(path, data)
    data.version = data.version or 1
    data.next_id = data.next_id or 1
    data.students = data.students or {}
    local content = cjson.encode(data)
    local tmp = path .. ".tmp"
    utils.write_file(tmp, content .. "\n")
    local ok, err = os.rename(tmp, path)
    if not ok then
        os.remove(tmp)
        error("failed to replace storage file: " .. tostring(err))
    end
end

-- @description: Create a timestamped backup copy when the data file exists.
-- @param path: string - JSON file path.
-- @return: string|nil - Backup path when created.
function M.backup(path)
    if not utils.file_exists(path) then
        return nil
    end
    local content = assert(utils.read_file(path))
    local backup_path = string.format("%s.%s.bak", path, os.date("!%Y%m%d%H%M%S"))
    utils.write_file(backup_path, content)
    return backup_path
end

return M
