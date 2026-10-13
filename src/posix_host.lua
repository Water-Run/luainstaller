--[[
Lazy bootstrap for the native POSIX process supervisor.

Author:
    WaterRun
File:
    posix_host.lua
Date:
    2026-10-12
Updated:
    2026-10-13
]]

local M = {}
local binary, bootstrap_error, configured_compiler, private_root, collecting

function M.configure(compiler)
    if not binary then configured_compiler = compiler end
end

function M.ready()
    return binary
end

local function writeSource(destination, content)
    local opened, handle, detail = pcall(io.open, destination, "wb")
    if not opened or not handle then return nil, tostring(detail or handle) end
    local wrote, value, write_error = pcall(handle.write, handle, content)
    local closed, result, close_error = pcall(handle.close, handle)
    if not wrote or not value or not closed or not result then
        return nil, tostring(write_error or close_error or value or result)
    end
    return true
end

local function cleanup(raw, quote)
    if collecting or not private_root then return end
    collecting = true
    local root = private_root
    private_root = nil
    -- Only these two names were created in the exclusively allocated directory.
    pcall(os.remove, root .. "/host.c")
    pcall(os.remove, root .. "/host")
    pcall(raw, "rmdir " .. quote(root), {timeout_seconds=5, max_output_bytes=4096})
end

function M.prepare(raw, quote)
    if binary then return binary end
    if bootstrap_error then return nil, bootstrap_error end
    local fs = require("luainstaller.fs")
    local root, err = fs.makePrivateDirectory("posix-host")
    if not root then return nil, tostring(err) end
    private_root = root
    local source = require("luainstaller.posix_host_source")
    local wrote, write_error = writeSource(root .. "/host.c", source)
    if not wrote then cleanup(raw, quote); return nil, write_error end
    local candidates, seen = {}, {}
    for _, candidate in ipairs({configured_compiler or "", os.getenv("LUAI_HOST_CC") or "",
        os.getenv("LUAI_CC") or "", os.getenv("CC") or "", "cc", "gcc", "clang"}) do
        if candidate ~= "" and not candidate:find("\0", 1, true) and not seen[candidate] then
            candidates[#candidates + 1], seen[candidate] = candidate, true
        end
    end
    local diagnostics = {}
    for _, candidate in ipairs(candidates) do
        local command = quote(candidate) .. " -std=c99 -O2 -Wall -Wextra -Werror -pedantic "
            .. quote(root .. "/host.c") .. " -o " .. quote(root .. "/host")
        local compiled, output = raw(command, {timeout_seconds=30, max_output_bytes=65536})
        if not compiled and tostring(output):find("clock_gettime", 1, true) then
            compiled, output = raw(command .. " -lrt", {timeout_seconds=30, max_output_bytes=65536})
        end
        if compiled then
            local checked = raw(quote(root .. "/host") .. " exec 1000 1024 LUAI_HOST_PROBE 0 -- "
                .. "sh -c 'exit 0'", {timeout_seconds=5, max_output_bytes=4096})
            if checked then binary = root .. "/host"; break end
        end
        diagnostics[#diagnostics + 1] = tostring(output or "supervisor did not run")
    end
    if not binary then
        bootstrap_error = "Cannot build native POSIX process supervision. Install a native C compiler "
            .. "or set LUAI_HOST_CC; static analysis remains available.\n"
            .. table.concat(diagnostics, "\n")
        cleanup(raw, quote)
        return nil, bootstrap_error
    end
    os.remove(root .. "/host.c")
    local owner
    if type(newproxy) == "function" then
        owner = newproxy(true)
        getmetatable(owner).__gc = function() cleanup(raw, quote) end
    else
        owner = setmetatable({}, {__gc=function() cleanup(raw, quote) end})
    end
    M._owner = owner
    return binary
end

function M.invocation(executable, arguments, environment, opts, token, raw, quote)
    local host, err = M.prepare(raw, quote)
    if not host then return nil, err end
    local keys = {}
    for key in pairs(environment or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    local parts = {"exec", quote(host), "exec", tostring(math.max(1, math.ceil(opts.timeout_seconds * 1000))),
        tostring(opts.max_output_bytes), quote(token), tostring(#keys)}
    for _, key in ipairs(keys) do parts[#parts + 1] = quote(key); parts[#parts + 1] = quote(environment[key]) end
    if opts.working_directory then
        parts[#parts + 1] = "--cwd"
        parts[#parts + 1] = quote(opts.working_directory)
    end
    parts[#parts + 1], parts[#parts + 2] = "--", quote(executable)
    for _, value in ipairs(arguments or {}) do parts[#parts + 1] = quote(value) end
    return table.concat(parts, " ")
end

return M
