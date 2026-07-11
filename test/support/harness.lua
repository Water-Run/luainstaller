--[[
@file test/support/harness.lua
@brief Shared helpers for luainstaller tests.

Author:
    WaterRun
File:
    harness.lua
Date:
    2026-06-27
Updated:
    2026-07-11
]]

local M = {}

local PRELOADS = {
    { "luainstaller", "src/init.lua" },
    { "luainstaller.fs", "src/fs.lua" },
    { "luainstaller.hash", "src/hash.lua" },
    { "luainstaller.path", "src/path.lua" },
    { "luainstaller.process", "src/process.lua" },
    { "luainstaller.result", "src/result.lua" },
    { "luainstaller.logger", "src/logger.lua" },
    { "luainstaller.analyzer", "src/analyzer.lua" },
    { "luainstaller.discovery", "src/discovery.lua" },
    { "luainstaller.compat", "src/compat.lua" },
    { "luainstaller.platform", "src/platform.lua" },
    { "luainstaller.manifest", "src/manifest.lua" },
    { "luainstaller.runtime", "src/runtime.lua" },
    { "luainstaller.cgen", "src/cgen.lua" },
    { "luainstaller.launcher", "src/launcher.lua" },
    { "luainstaller.bundler", "src/bundler.lua" },
    { "luainstaller.onefile", "src/onefile.lua" },
    { "luainstaller.cli", "src/cli.lua" },
}

function M.install_loader()
    package.path = table.concat({
        "src/?.lua",
        "src/?/init.lua",
        package.path,
    }, ";")

    for _, item in ipairs(PRELOADS) do
        local module_name = item[1]
        local file_path = item[2]
        package.preload[module_name] = package.preload[module_name] or function(name)
            return assert(loadfile(file_path))(name)
        end
    end
end

function M.loader_prelude()
    return [[
local harness = dofile("test/support/harness.lua")
harness.install_loader()
]]
end

function M.shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.run(command)
    local pipe = assert(io.popen(command .. " 2>&1", "r"))
    local output = pipe:read("*a") or ""
    local ok, _, code = pipe:close()
    if not ok then
        error("command failed (" .. tostring(code) .. "): " .. command .. "\n" .. output, 2)
    end
    return output
end

function M.command_output_trimmed(command)
    local output = M.run(command)
    return (output:gsub("%s+$", ""))
end

function M.file_exists(path)
    local handle = io.open(path, "rb")
    if not handle then
        return false
    end
    handle:close()
    return true
end

function M.read_file(path)
    local handle = assert(io.open(path, "rb"))
    local data = assert(handle:read("*a"))
    handle:close()
    return data
end

function M.write_file(path, content)
    local handle = assert(io.open(path, "wb"))
    assert(handle:write(content))
    handle:close()
end

function M.assert_contains(text, needle)
    if not tostring(text):find(needle, 1, true) then
        error("expected text to contain " .. needle .. "\nactual:\n" .. tostring(text), 2)
    end
end

function M.assert_not_contains(text, needle)
    if tostring(text):find(needle, 1, true) then
        error("expected text not to contain " .. needle .. "\nactual:\n" .. tostring(text), 2)
    end
end

function M.make_temp_dir(name)
    local template = "/tmp/luainstaller-contract-" .. name .. "-XXXXXX"
    return M.command_output_trimmed("mktemp -d " .. M.shell_quote(template))
end

function M.remove_tree(path)
    if path and path:match("^/tmp/luainstaller%-contract%-") then
        M.run("rm -rf " .. M.shell_quote(path))
    end
end

function M.mkdir(path)
    M.run("mkdir -p " .. M.shell_quote(path))
end

function M.find_trace(trace, requested)
    for _, item in ipairs(trace or {}) do
        if item.requested == requested then
            return item
        end
    end
    return nil
end

function M.assert_error(result, error_type, option)
    assert(result.ok == false, "expected failure")
    assert(result.error, "expected structured error")
    assert(result.error.type == error_type,
        "expected " .. error_type .. ", got " .. tostring(result.error.type))
    assert(type(result.error.message) == "string" and result.error.message ~= "")
    if option then
        assert(result.error.option == option,
            "expected option " .. option .. ", got " .. tostring(result.error.option))
    end
end

function M.invoke_cli(program, argv)
    local cli = require("luainstaller.cli")
    local old_arg = _G.arg
    _G.arg = { [0] = program }
    for i, value in ipairs(argv) do
        _G.arg[i] = value
    end

    local out, err = {}, {}
    local old_stdout, old_stderr = io.stdout, io.stderr
    local old_write = io.write
    io.write = function(value)
        out[#out + 1] = tostring(value)
    end
    io.stdout = { write = function(_, value) out[#out + 1] = tostring(value) end }
    io.stderr = { write = function(_, value) err[#err + 1] = tostring(value) end }

    local ok, code = pcall(cli.main, argv, { program = program })
    io.stdout, io.stderr = old_stdout, old_stderr
    io.write = old_write
    _G.arg = old_arg
    if not ok then
        error(code, 2)
    end
    return code, table.concat(out), table.concat(err)
end

return M
