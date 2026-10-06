--[[
Checked filesystem primitives for luainstaller.

Author:
    WaterRun
File:
    fs.lua
Date:
    2026-07-11
Updated:
    2026-10-06
]]

if package.config:sub(1, 1) == "\\" then
    return require("luainstaller.windows_fs")
end

local process = require("luainstaller.process")
local M = {}


local function validPath(path)
    return type(path) == "string" and path ~= "" and not path:find("\0", 1, true)
end

local function trustedRootDirectoryLink(path)
    if type(path) ~= "string" then return false end
    local normalized = path:gsub("/+$", "")
    if not normalized:match("^/[^/]+$") then return false end
    local quoted = process.quote(normalized)
    if not process.output("test -d " .. quoted) then return false end
    local listed, output = process.output("LC_ALL=C ls -ldn " .. quoted)
    if not listed then return false end
    local owner = tostring(output):match("^%S+%s+%d+%s+(%d+)%s+")
    if owner ~= "0" then return false end
    -- The resolved target must itself be a root-owned directory; a root-owned
    -- link to a user-controlled directory is not a system path.
    local resolved, target_output = process.output("LC_ALL=C ls -ldnL " .. quoted)
    if not resolved then return false end
    local target_line = tostring(target_output)
    local target_owner = target_line:match("^%S+%s+%d+%s+(%d+)%s+")
    return target_line:sub(1, 1) == "d" and target_owner == "0"
end

local function operationError(operation, path, detail)
    return string.format(
        "Cannot %s file %s: %s",
        operation,
        tostring(path),
        tostring(detail or "unknown filesystem error")
    )
end


function M.readFile(path)
    local opened, handle, open_err = pcall(io.open, path, "rb")
    if not opened then
        return nil, operationError("open", path, handle)
    end
    if not handle then
        return nil, operationError("open", path, open_err)
    end

    local read_ok, content, read_err = pcall(handle.read, handle, "*a")
    local close_ok, closed, close_err = pcall(handle.close, handle)
    if not read_ok then
        return nil, operationError("read", path, content)
    end
    if content == nil then
        return nil, operationError("read", path, read_err)
    end
    if not close_ok then
        return nil, operationError("close", path, closed)
    end
    if not closed then
        return nil, operationError("close", path, close_err)
    end
    return content
end

function M.isRegularFile(path)
    return M.pathType(path) == "file"
end

function M.readRegularFile(path)
    if not M.isRegularFile(path) then
        return nil, operationError("read", path, "path is not a regular file")
    end
    return M.readFile(path)
end

function M.writeFile(path, content)
    if content == nil then
        content = ""
    end
    if type(content) ~= "string" then
        return nil, operationError("write", path, "content must be a string")
    end
    local opened, handle, open_err = pcall(io.open, path, "wb")
    if not opened then
        return nil, operationError("open", path, handle)
    end
    if not handle then
        return nil, operationError("open", path, open_err)
    end

    local write_ok, wrote, write_err = pcall(handle.write, handle, content)
    local flush_ok, flushed, flush_err = pcall(handle.flush, handle)
    local close_ok, closed, close_err = pcall(handle.close, handle)

    if not write_ok then
        return nil, operationError("write", path, wrote)
    end
    if not wrote then
        return nil, operationError("write", path, write_err)
    end
    if not flush_ok then
        return nil, operationError("flush", path, flushed)
    end
    if not flushed then
        return nil, operationError("flush", path, flush_err)
    end
    if not close_ok then
        return nil, operationError("close", path, closed)
    end
    if not closed then
        return nil, operationError("close", path, close_err)
    end
    return true
end

function M.pathType(path)
    if not validPath(path) then return "other" end
    local quoted = process.quote(path)
    if process.output("test -L " .. quoted) then return "reparse" end
    if process.output("test -f " .. quoted) then return "file" end
    if process.output("test -d " .. quoted) then return "directory" end
    if process.output("test -e " .. quoted) then return "other" end
    return "missing"
end

function M.makeDirectory(path)
    if not validPath(path) then return nil, "directory path is invalid" end
    local ok, output = process.output("mkdir -p -m 700 " .. process.quote(path))
    if not ok then return nil, output end
    local kind = M.pathType(path)
    if kind == "directory" or (kind == "reparse" and trustedRootDirectoryLink(path)) then
        return true
    end
    return nil, "path is not a safe directory"
end

function M.createDirectory(path)
    if not validPath(path) then return nil, "directory path is invalid" end
    if M.pathType(path) ~= "missing" then return nil, "directory already exists" end
    local ok, output = process.output("mkdir -m 700 " .. process.quote(path))
    if not ok then return nil, output end
    return true
end

function M.removeDirectory(path)
    if M.pathType(path) ~= "directory" then return nil, "path is not a safe directory" end
    local ok, output = process.output("rmdir " .. process.quote(path))
    if not ok then return nil, output end
    return true
end

function M.modifiedAt(path)
    if M.pathType(path) == "missing" then return nil end
    local value = process.firstLine("stat -c %Y " .. process.quote(path) .. " 2>/dev/null")
    if not tonumber(value) then
        value = process.firstLine("stat -f %m " .. process.quote(path) .. " 2>/dev/null")
    end
    return tonumber(value)
end

function M.temporaryRoot()
    local configured = os.getenv("TMPDIR") or os.getenv("TEMP") or os.getenv("TMP")
    local prefix = os.getenv("TERMUX__PREFIX") or os.getenv("PREFIX")
        or os.getenv("TERMUX_PREFIX")
    local android = os.getenv("TERMUX_VERSION") ~= nil
        or os.getenv("ANDROID_ROOT") ~= nil
        or (type(prefix) == "string"
            and prefix:find("com.termux/files/usr", 1, true) ~= nil)
    if android and (not configured or configured == "" or configured == "/tmp")
        and type(prefix) == "string" and prefix ~= "" then
        return prefix:gsub("[/\\]+$", "") .. "/tmp"
    end
    if configured and configured ~= "" then return configured end
    return "/tmp"
end

function M.makePrivateDirectory(label, parent)
    label = tostring(label or "private"):gsub("[^%w_-]", "-")
    if not parent then parent = M.temporaryRoot() end
    local made, make_err = M.makeDirectory(parent)
    if not made then return nil, make_err end
    for attempt = 1, 40 do
        local suffix = table.concat({
            tostring(os.time()),
            tostring(math.floor(os.clock() * 1000000000)),
            tostring({}):gsub("[^%w]", ""),
            tostring(attempt),
        }, "-")
        local separator = parent:match("[/\\]$") and "" or package.config:sub(1, 1)
        local candidate = parent .. separator .. "luainstaller-" .. label .. "-" .. suffix
        local ok = process.output("mkdir -m 700 " .. process.quote(candidate))
        if ok then return candidate end
    end
    return nil, "cannot create a unique private directory"
end

function M.copyFile(source, destination)
    if not validPath(destination) then return nil, "destination path is invalid" end
    if M.pathType(source) ~= "file" then return nil, "source is not a regular file" end
    if M.pathType(destination) ~= "missing" then
        return nil, "destination already exists"
    end
    local ok, output = process.output(
        "cp " .. process.quote(source) .. " " .. process.quote(destination)
    )
    if not ok then return nil, output end
    return true
end

function M.rename(source, destination)
    if not validPath(source) or not validPath(destination) then
        return nil, "source or destination path is invalid"
    end
    local source_type = M.pathType(source)
    if source_type ~= "file" and source_type ~= "directory" then
        return nil, "source is not a safe file or directory"
    end
    if M.pathType(destination) ~= "missing" then
        return nil, "destination already exists"
    end
    local ok, err = os.rename(source, destination)
    if not ok then return nil, err end
    return true
end

function M.hardLink(source, destination)
    if not validPath(source) or not validPath(destination) then
        return nil, "source or destination path is invalid"
    end
    if M.pathType(source) ~= "file" then
        return nil, "source is not a safe regular file"
    end
    if M.pathType(destination) ~= "missing" then
        return nil, "destination already exists"
    end
    local ok, output = process.outputCommand("ln", { source, destination })
    if not ok then return nil, output end
    return true
end

function M.isExecutable(path)
    if M.pathType(path) ~= "file" then return false end
    local ok = process.outputCommand("test", { "-x", path })
    return ok == true
end

function M.setExecutable(path)
    if M.pathType(path) ~= "file" then return nil, "path is not a regular file" end
    local ok, output = process.outputCommand("chmod", { "+x", path })
    if not ok then return nil, output end
    return true
end

function M.listTree(root)
    if M.pathType(root) ~= "directory" then return nil, "tree root is not a directory" end
    local entries = {}
    -- BSD find has -print0 but not GNU find's -mindepth.  Exclude the
    -- explicitly quoted root instead, preserving NUL-safe inventories.
    local quoted_root = process.quote(root)
    local ok, output = process.output(
        "find " .. quoted_root .. " ! -path " .. quoted_root .. " -print0"
    )
    if not ok then return nil, output end
    output = tostring(output)
    local position = 1
    while position <= #output do
        local terminator = output:find("\0", position, true)
        if not terminator then return nil, "incomplete POSIX tree inventory" end
        local absolute = output:sub(position, terminator - 1)
        local relative = absolute:sub(#root + 1):gsub("^/", "")
        entries[#entries + 1] = { path = relative, type = M.pathType(absolute) }
        position = terminator + 1
    end
    table.sort(entries, function(left, right) return left.path < right.path end)
    return entries
end

function M.removeFile(path)
    local kind = M.pathType(path)
    if kind ~= "file" and kind ~= "reparse" then
        return nil, "path is not a removable file or reparse point"
    end
    local ok, err = os.remove(path)
    if not ok then return nil, err end
    return true
end

function M.removeTree(root)
    local entries, list_err = M.listTree(root)
    if not entries then return nil, list_err end
    for _, entry in ipairs(entries) do
        if entry.type == "reparse" then
            return nil, "refusing to remove a tree containing a reparse point: " .. entry.path
        end
        if entry.type == "other" then
            return nil, "refusing to remove a tree containing an unsafe entry: " .. entry.path
        end
    end
    local ok, output = process.output("rm -rf " .. process.quote(root))
    if not ok then return nil, output end
    return true
end

return M
