--[[
Checked Windows filesystem operations using the XP-compatible native host.

Author:
    WaterRun
File:
    windows_fs.lua
Date:
    2026-10-06
Updated:
    2026-10-06
]]

local host = require("luainstaller.windows_host")
local M = {}

local function valid(value)
    return type(value) == "string" and value ~= "" and not value:find("\0", 1, true)
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

function M.readFile(value)
    if not valid(value) then return nil, "file path is invalid" end
    local ok, output = host.call("read", value)
    if not ok then return nil, output end
    return output
end

function M.readRegularFile(value)
    if not M.isRegularFile(value) then return nil, "path is not a regular file: " .. tostring(value) end
    return M.readFile(value)
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
