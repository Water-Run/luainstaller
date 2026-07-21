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
    2026-07-18
]]

local M = {}
local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local command_counter = 0

local function legacy_windows_script(command, token)
    local identity = tostring({}):gsub("[^%w]", "")
    for attempt = 1, 100 do
        local path = string.format(
            "luai-test-command-%s-%d-%d-%d.cmd",
            identity,
            os.time(),
            command_counter,
            attempt
        )
        local existing = io.open(path, "rb")
        if existing then
            existing:close()
        else
            local handle, err = io.open(path, "wb")
            if not handle then return nil, err end
            local content = table.concat({
                "@echo off",
                "call :luai_test_command",
                'set "LUAI_TEST_STATUS=%errorlevel%"',
                '<nul set /p "=' .. token .. ':%LUAI_TEST_STATUS%"',
                'exit /b %LUAI_TEST_STATUS%',
                ':luai_test_command',
                command,
                'exit /b %errorlevel%',
                "",
            }, "\r\n")
            local wrote, write_err = handle:write(content)
            local closed, close_err = handle:close()
            if not wrote or not closed then
                os.remove(path)
                return nil, tostring(write_err or close_err)
            end
            return path
        end
    end
    return nil, "cannot allocate a unique Windows command script"
end

local function quote_windows(value)
    value = tostring(value or "")
    if value == "" then
        return '""'
    end
    if not value:find('[%s"]') then
        return value
    end
    local output = { '"' }
    local slashes = 0
    for index = 1, #value do
        local character = value:sub(index, index)
        if character == "\\" then
            slashes = slashes + 1
        elseif character == '"' then
            output[#output + 1] = string.rep("\\", slashes * 2 + 1)
            output[#output + 1] = '"'
            slashes = 0
        else
            output[#output + 1] = string.rep("\\", slashes)
            output[#output + 1] = character
            slashes = 0
        end
    end
    output[#output + 1] = string.rep("\\", slashes * 2)
    output[#output + 1] = '"'
    return table.concat(output)
end

local PRELOADS = {
    { "luainstaller", "src/init.lua" },
    { "luainstaller.fs", "src/fs.lua" },
    { "luainstaller.hash", "src/hash.lua" },
    { "luainstaller.path", "src/path.lua" },
    { "luainstaller.process", "src/process.lua" },
    { "luainstaller.toolchain", "src/toolchain.lua" },
    { "luainstaller.result", "src/result.lua" },
    { "luainstaller.lock_owner", "src/lock_owner.lua" },
    { "luainstaller.distribution_files", "src/distribution_files.lua" },
    { "luainstaller.lua_abi", "src/lua_abi.lua" },
    { "luainstaller.native_profile", "src/native_profile.lua" },
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
    if IS_WINDOWS then
        return quote_windows(value)
    end
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.command(executable, arguments)
    local parts = { M.shell_quote(executable) }
    for _, value in ipairs(arguments or {}) do
        parts[#parts + 1] = M.shell_quote(value)
    end
    return table.concat(parts, " ")
end

function M.command_result(command)
    command_counter = command_counter + 1
    local invocation = command .. " 2>&1"
    local legacy_token
    local legacy_script
    if _VERSION == "Lua 5.1" then
        legacy_token = string.format(
            "LUAI_TEST_EXIT_%s_%d_%d",
            tostring({}):gsub("[^%w]", ""),
            os.time(),
            command_counter
        )
        if IS_WINDOWS then
            local script_err
            legacy_script, script_err = legacy_windows_script(command, legacy_token)
            if not legacy_script then return false, tostring(script_err), nil end
            invocation = "call " .. quote_windows(legacy_script) .. " 2>&1"
        else
            invocation = "(" .. command .. ") 2>&1; "
                .. "__luai_test_status=$?; printf '\n" .. legacy_token
                .. ":%s\n' \"$__luai_test_status\""
        end
    end

    local opened, pipe = pcall(io.popen, invocation, "r")
    if not opened or not pipe then
        if legacy_script then os.remove(legacy_script) end
        return false, tostring(pipe), nil
    end
    local output = pipe:read("*a") or ""
    local close_ok, _, close_code = pipe:close()
    if legacy_script then
        local removed, remove_err = os.remove(legacy_script)
        if not removed then
            return false, output .. "\nfailed to remove command script: "
                .. tostring(remove_err), nil
        end
    end
    if legacy_token then
        local marker_prefix = IS_WINDOWS and "" or "\n"
        local captured, status = output:match(
            "^(.*)" .. marker_prefix .. legacy_token .. ":(%d+)\r?\n?$"
        )
        if not status then
            return false, output, nil
        end
        status = tonumber(status)
        return status == 0, captured, status
    end
    if close_ok == true then
        return true, output, 0
    end
    return false, output, tonumber(close_code)
end

function M.run(command)
    local ok, output, code = M.command_result(command)
    if not ok then
        error("command failed (" .. tostring(code) .. "): " .. command .. "\n" .. output, 2)
    end
    return output
end

function M.lua_command()
    local configured = os.getenv("LUAI_TEST_LUA")
    if configured and configured ~= "" then
        return configured
    end
    local current = arg and arg[-1]
    if current and current ~= "" then
        return current
    end
    return "lua"
end

function M.luac_command()
    local configured = os.getenv("LUAI_TEST_LUAC")
    if configured and configured ~= "" then
        return configured
    end
    local lua = M.lua_command()
    local sibling, replacements = lua:gsub("lua(%.[Ee][Xx][Ee])$", "luac%1", 1)
    if replacements == 0 then
        sibling, replacements = lua:gsub("lua$", "luac", 1)
    end
    if replacements > 0 then
        return sibling
    end
    return "luac"
end

function M.run_lua(arguments)
    return M.run(M.command(M.lua_command(), arguments))
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

function M.assert_pe_closure(config, artifacts)
    if not IS_WINDOWS then return end
    assert(config and config.dumpbin, "dumpbin is required for PE closure checks")
    local process = require("luainstaller.process")
    for _, artifact in ipairs(artifacts or {}) do
        local ok, output = process.outputCommand(config.dumpbin, {
            "/nologo", "/dependents", artifact,
        }, config.environment)
        assert(ok, tostring(output))
        for line in tostring(output):gmatch("[^\r\n]+") do
            local dependency = line:match("^%s*([^%s]+%.dll)%s*$")
            local upper = dependency and dependency:upper() or ""
            assert(not upper:match("^VCRUNTIME%d*%.DLL$")
                and not upper:match("^MSVCP%d*%.DLL$")
                and upper ~= "UCRTBASE.DLL",
                "unexpected dynamic CRT dependency in " .. artifact .. ": " .. upper)
        end
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
