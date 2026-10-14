--[[
Checked Windows filesystem operations using the XP-compatible native host.

Author:
    WaterRun
File:
    windows_fs.lua
Date:
    2026-10-06
Updated:
    2026-10-13
]]

local host = require("luainstaller.windows_host")
local M = {}

function M.guardOutputParents(value, previous)
    return require("luainstaller.process").guardOutputParents(value, previous)
end

function M.fileSize(value)
    local ok, output = host.call("file_size", value)
    return ok and tonumber(output) or nil, not ok and output or nil
end

local function valid(value)
    return type(value) == "string" and value ~= "" and not value:find("\0", 1, true)
end

function M.sameFile(first, second)
    if not valid(first) or not valid(second) then return nil, "source paths are invalid" end
    local first_ok, first_id = host.call("file_identity", first)
    if not first_ok then return nil, first_id end
    local second_ok, second_id = host.call("file_identity", second)
    if not second_ok then return nil, second_id end
    return first_id == second_id
end

local function operation(name, ...)
    local ok, output = host.call(name, ...)
    if not ok then return nil, output end
    return true
end

function M.pathType(value)
    if not valid(value) then return "other" end
    local ok, output = host.call("type", value)
    if not ok then return "other", output end
    return output
end

function M.isRegularFile(value)
    return M.pathType(value) == "file"
end

function M.readFile(value, limit)
    if not valid(value) then return nil, "file path is invalid" end
    limit = limit or 64 * 1024 * 1024
    if type(limit) ~= "number" or limit ~= limit or limit < 1 or limit > 1073741824
        or limit ~= math.floor(limit) then return nil, "file read limit is invalid" end
    local ok, output = host.call("read", value, tostring(limit))
    if not ok then
        return nil, output, tostring(output):find("file exceeds read limit", 1, true)
            and {limit_exceeded=true, resource="file-bytes", limit=limit, path=value} or nil
    end
    return output
end

function M.readRegularFile(value, limit)
    if not M.isRegularFile(value) then return nil, "path is not a regular file: " .. tostring(value) end
    return M.readFile(value, limit)
end

function M.writeFile(value, content)
    if not valid(value) then return nil, "file path is invalid" end
    if content == nil then content = "" end
    if type(content) ~= "string" then return nil, "content must be a string" end
    return operation("write", value, content)
end

function M.makeDirectory(value)
    if not valid(value) then return nil, "directory path is invalid" end
    return operation("mkdir", value)
end

function M.createDirectory(value)
    if not valid(value) then return nil, "directory path is invalid" end
    return operation("create_dir", value)
end

function M.removeDirectory(value)
    if not valid(value) then return nil, "directory path is invalid" end
    return operation("rmdir", value)
end

function M.modifiedAt(value)
    if not valid(value) then return nil end
    local ok, output = host.call("mtime", value)
    return ok and tonumber(output) or nil
end

function M.temporaryRoot()
    for _, name in ipairs({ "TEMP", "TMP" }) do
        local ok, output = host.call("env", name)
        if ok and output ~= "" then return output end
    end
    return "."
end

function M.writeChunks(path, producer, limit)
    local made, err = M.writeFile(path, "")
    if not made then return nil, err end
    local chunks, bytes, total = {}, 0, 0
    local function flush()
        if bytes == 0 then return end
        local wrote, detail = operation("append", path, table.concat(chunks))
        if not wrote then error({type="FilesystemError", path=path, message=detail}, 0) end
        chunks, bytes = {}, 0
    end
    local called, failure = pcall(function()
        producer(function(chunk)
            if type(chunk) ~= "string" then error("write chunk must be a string", 0) end
            total = total + #chunk
            if total > (limit or 1073741824) then
                error({type="ResourceLimitExceededError", resource="generated-source-bytes",
                    limit=limit or 1073741824, path=path, current_bytes=total,
                    message="Generated source exceeds its byte limit"}, 0)
            end
            chunks[#chunks + 1], bytes = chunk, bytes + #chunk
            if bytes >= 262144 then flush() end
        end)
        flush()
    end)
    if not called then return nil, failure end
    return true
end

function M.makePrivateDirectory(label, parent)
    label = tostring(label or "private"):gsub("[^%w_-]", "-")
    parent = parent or M.temporaryRoot()
    local made, err = M.makeDirectory(parent)
    if not made then return nil, err end
    local ok, output = host.call("private", label, parent)
    if not ok then return nil, output end
    return (output:gsub("\\", "/"))
end

function M.copyFile(source, destination)
    if not valid(source) or not valid(destination) then return nil, "source or destination path is invalid" end
    return operation("copy", source, destination)
end

function M.rename(source, destination)
    if not valid(source) or not valid(destination) then return nil, "source or destination path is invalid" end
    return operation("rename", source, destination)
end

function M.hardLink(source, destination)
    if not valid(source) or not valid(destination) then return nil, "source or destination path is invalid" end
    return operation("link", source, destination)
end

function M.isExecutable(value)
    return M.pathType(value) == "file"
end

function M.setExecutable(value)
    if not M.isExecutable(value) then return nil, "path is not a regular file" end
    return true
end

local function inventory(name, root)
    if not valid(root) then return nil, "tree path is invalid" end
    local ok, output = host.call(name, root)
    if not ok then return nil, output end
    local entries, position = {}, 1
    while position <= #output do
        local kind_end = output:find("\0", position, true)
        local path_end = kind_end and output:find("\0", kind_end + 1, true)
        if not path_end then return nil, "incomplete native tree inventory" end
        entries[#entries + 1] = {
            type = output:sub(position, kind_end - 1),
            path = output:sub(kind_end + 1, path_end - 1):gsub("\\", "/"),
        }
        position = path_end + 1
    end
    table.sort(entries, function(left, right) return left.path < right.path end)
    return entries
end

function M.listTree(root)
    return inventory("list", root)
end

function M.listDirectory(root)
    return inventory("children", root)
end

function M.removeFile(value)
    if not valid(value) then return nil, "file path is invalid" end
    return operation("remove", value)
end

function M.removeTree(root)
    if not valid(root) then return nil, "tree path is invalid" end
    return operation("remove_tree", root)
end

return M
