--[[
Native Windows host bridge, bootstrapped with the build machine's C compiler.

Author:
    WaterRun
File:
    windows_host.lua
Date:
    2026-10-06
Updated:
    2026-10-06
]]

local M = {}
local loaded, load_error, compiler_context, loaded_path, source_id
local configured_cc
local windows = package.config:sub(1, 1) == "\\"

local function records(data)
    local out, position = {}, 1
    while position <= #data do
        local split = data:find("\0", position, true)
        local finish = split and data:find("\0", split + 1, true)
        if not finish then return nil end
        out[#out + 1] = { kind = data:sub(position, split - 1), name = data:sub(split + 1, finish - 1) }
        position = finish + 1
    end
    return out
end

local function cleanup_previous(parent, current)
    local ok, inventory = M.call("children", parent)
    if not ok then return end
    for _, entry in ipairs(records(inventory) or {}) do
        if entry.kind == "directory" and entry.name:match("^luainstaller%-wh%-%d+%-[%w]+%-%d+$") then
            local root = parent .. "\\" .. entry.name
            if root ~= current then
                local owner_ok, owner = M.call("owner", root)
                local read_ok, marker, pid, digest
                if owner_ok and owner == "yes" then
                    local typed, kind = M.call("type", root .. "\\owner")
                    if typed and kind == "file" then read_ok, marker = M.call("read", root .. "\\owner", "256") end
                end
                if read_ok then pid, digest = marker:match("^luainstaller%-windows%-host%-v1\npid=(%d+)\nhash=([0-9a-f]+)\n$") end
                if owner_ok and owner == "yes" and pid and digest and #digest == 64 then
                    local checked, alive = M.call("alive", pid)
                    local listed, contents = M.call("children", root)
                    local entries = listed and records(contents)
                    local safe = checked and alive == "no" and entries and #entries == 2
                    for _, item in ipairs(entries or {}) do
                        if item.kind ~= "file" or (item.name ~= "host.dll" and item.name ~= "owner") then safe = false end
                    end
                    if safe then
                        local read, bytes = M.call("read", root .. "\\host.dll")
                        if read and require("luainstaller.hash").sha256(bytes) == digest
                            and M.call("remove", root .. "\\host.dll") then
                            M.call("remove", root .. "\\owner")
                            M.call("rmdir", root)
                        end
                    end
                end
            end
        end
    end
end

local function read_file(name)
    local handle = io.open(name, "rb")
    if not handle then return nil end
    local data = handle:read("*a")
    handle:close()
    return data
end

local function write_file(name, data)
    local handle, err = io.open(name, "wb")
    if not handle then return nil, err end
    local wrote, write_err = handle:write(data)
    local closed, close_err = handle:close()
    if not wrote or not closed then return nil, write_err or close_err end
    return true
end

local function succeeded(first, _, third)
    return first == true or first == 0 or (first == nil and third == 0)
end

local function batch_path(value)
    if type(value) ~= "string" or value == "" or value:find('[%c"]') then
        return nil
    end
    -- A batch file expands %% to a literal percent. Delayed expansion is
    -- disabled before any data appears, and Windows filenames cannot contain
    -- quotes. Keep this separate from CreateProcess argument quoting.
    return '"' .. value:gsub("/", "\\"):gsub("%%", "%%%%") .. '"'
end

local function requested_compiler()
    if configured_cc then return configured_cc end
    local value = os.getenv("LUAI_CC") or os.getenv("CC")
    if value and value ~= "" then return value end
    for index = 1, #(arg or {}) do
        if arg[index] == "--cc" then return arg[index + 1] end
        local selected = arg[index]:match("^%-%-cc=(.+)$")
        if selected then return selected end
    end
end

function M.configure(cc)
    if cc and not loaded then configured_cc = cc; load_error = nil end
end

local function bootstrap()
    if loaded then return loaded end
    if load_error then return nil, load_error end
    if not windows then return nil, "native Windows operations require Windows" end
    local abi = _VERSION:match("^Lua 5%.([1-5])$")
    if not abi or rawget(_G, "jit") then return nil, "official Lua 5.1 through 5.5 is required" end
    local source = require("luainstaller.windows_host_source")
    source_id = source_id or require("luainstaller.hash").sha256(source)
    local inherited = os.getenv("LUAI_WINDOWS_HOST_DLL")
    if inherited and os.getenv("LUAI_WINDOWS_HOST_ABI") == _VERSION
        and os.getenv("LUAI_WINDOWS_HOST_ID") == source_id then
        local open = package.loadlib(inherited, "luaopen_luainstaller_windows_host")
        local called, module
        if open then called, module = pcall(open) end
        if called and type(module) == "table" and type(module.request) == "function" then
            loaded, loaded_path = module, inherited
            compiler_context = { cc = requested_compiler(), environment = {} }
            return loaded
        end
    end
    local parent_key = os.getenv("TEMP") and "TEMP" or os.getenv("TMP") and "TMP"
    local parent = parent_key and os.getenv(parent_key)
    if not parent or parent == "" or parent:find('[%c"]') then
        return nil, "Windows needs an existing TEMP or TMP directory"
    end
    parent = parent:gsub("/", "\\"):gsub("\\+$", "")
    local username, domain = os.getenv("USERNAME"), os.getenv("USERDOMAIN")
    if not username or username == "" or username:find('[%c"]') then
        return nil, "Windows needs a valid USERNAME environment value"
    end
    local cc = requested_compiler()
    if cc and not batch_path(cc) then return nil, "the compiler path is invalid" end
    local suffix = tostring(os.time()) .. "-" .. tostring({}):gsub("[^%w]", "")
    local root, reference
    for attempt = 1, 40 do
        local name = "luainstaller-wh-" .. suffix .. "-" .. tostring(attempt)
        local symbolic = '"%' .. parent_key .. '%\\' .. name .. '"'
        if succeeded(os.execute("mkdir " .. symbolic .. " >NUL 2>&1")) then
            root, reference = parent .. "\\" .. name, "%" .. parent_key .. "%\\" .. name
            break
        end
    end
    if not root then return nil, "cannot create a private Windows build directory" end
    -- Restrict access before writing executable build inputs. CACLS ships
    -- with XP; an ACL failure is a failed bootstrap rather than a weak cache.
    local protected = false
    if domain and domain ~= "" and not domain:find('[%c"]') then
        protected = succeeded(os.execute('echo Y|cacls "' .. reference
            .. '" /P "%USERDOMAIN%\\%USERNAME%:F" >NUL 2>&1'))
    end
    if not protected then
        protected = succeeded(os.execute('echo Y|cacls "' .. reference
            .. '" /P "%USERNAME%:F" >NUL 2>&1'))
    end
    if not protected then
        return nil, "cannot protect native Windows build directory: " .. root
    end
    local wrote, err = write_file(root .. "\\host.c", source)
    if not wrote then return nil, "cannot stage Windows host source: " .. tostring(err) end
    wrote, err = write_file(root .. "\\host.def",
        "EXPORTS\r\n    luaopen_luainstaller_windows_host\r\n    luainstaller_host_watchdogW\r\n")
    if not wrote then return nil, tostring(err) end
    local compile_gcc = ' -std=c99 -O2 -Wall -Wextra -Werror=implicit-function-declaration'
        .. ' -shared -static-libgcc -DLUAI_HOST_ABI=50' .. abi
        .. ' host.c host.def -o host.dll -ladvapi32'
    local compile_msvc = ' /nologo /O2 /LD /MT /W4 /WX /wd5105 /DLUAI_HOST_ABI=50'
        .. abi .. ' host.c /Fo:host.obj /Fe:host.dll /link /DEF:host.def /INCREMENTAL:NO advapi32.lib'
    local lines = {
        "@echo off", "setlocal DisableDelayedExpansion",
        'cd /d "' .. reference .. '"',
        "if errorlevel 1 exit /b 1",
    }
    local function compile(command, msvc)
        lines[#lines + 1] = batch_path(command) .. (msvc and compile_msvc or compile_gcc) .. " >>build.log 2>&1"
        lines[#lines + 1] = "if not errorlevel 1 ("
        lines[#lines + 1] = "  for %%I in (" .. batch_path(command) .. ") do @echo %%~$PATH:I >compiler.txt"
        lines[#lines + 1] = "  set INCLUDE >include.txt 2>NUL"
        lines[#lines + 1] = "  set LIB >lib.txt 2>NUL"
        lines[#lines + 1] = "  set PATH >path.txt 2>NUL"
        lines[#lines + 1] = "  exit /b 0"
        lines[#lines + 1] = ")"
    end
    if cc then
        local name = cc:match("[^/\\]+$"):lower()
        compile(cc, name == "cl" or name == "cl.exe" or name:find("clang%-cl") ~= nil)
    else
        compile("cl.exe", true)
        compile("gcc.exe", false)
        compile("clang.exe", false)
        -- Modern Visual Studio installs can be discovered without executing
        -- PowerShell. XP toolchains normally already run in their own prompt.
        lines[#lines + 1] = 'set "LUAI_VSWHERE=%ProgramFiles(x86)%\\Microsoft Visual Studio\\Installer\\vswhere.exe"'
        lines[#lines + 1] = 'if not exist "%LUAI_VSWHERE%" set "LUAI_VSWHERE=%ProgramFiles%\\Microsoft Visual Studio\\Installer\\vswhere.exe"'
        lines[#lines + 1] = 'if not exist "%LUAI_VSWHERE%" exit /b 1'
        lines[#lines + 1] = 'for /f "usebackq tokens=*" %%I in (`"%LUAI_VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "LUAI_VS=%%I"'
        local arch = tostring(os.getenv("PROCESSOR_ARCHITECTURE") or "x86"):lower()
        local target = ({ amd64 = "x64", x86 = "x86", arm64 = "amd64_arm64", arm = "amd64_arm" })[arch] or "x86"
        lines[#lines + 1] = 'call "%LUAI_VS%\\VC\\Auxiliary\\Build\\vcvarsall.bat" ' .. target .. ' >>build.log 2>&1'
        lines[#lines + 1] = "if errorlevel 1 exit /b 1"
        compile("cl.exe", true)
    end
    lines[#lines + 1] = "exit /b 1"
    wrote, err = write_file(root .. "\\build.cmd", table.concat(lines, "\r\n") .. "\r\n")
    if not wrote then return nil, tostring(err) end
    local command = '"' .. reference .. '\\build.cmd"'
    if not succeeded(os.execute(command)) then
        load_error = "Cannot compile native Windows support. Use a native C compiler's command prompt or LUAI_CC.\n"
            .. tostring(read_file(root .. "\\build.log") or "compiler did not produce a log")
        return nil, load_error
    end
    local open, open_error = package.loadlib(root .. "\\host.dll", "luaopen_luainstaller_windows_host")
    if not open then load_error = tostring(open_error); return nil, load_error end
    local called, module = pcall(open)
    if not called or type(module) ~= "table" or type(module.request) ~= "function" then
        load_error = "Cannot bind the running interpreter's official Lua DLL API: " .. tostring(module)
        return nil, load_error
    end
    loaded, loaded_path = module, root .. "\\host.dll"
    compiler_context = { cc = cc, environment = {} }
    local located = read_file(root .. "\\compiler.txt")
    located = located and located:gsub("%s+$", "")
    if located and located ~= "" then compiler_context.cc = located end
    for _, name in ipairs({ "include", "lib", "path" }) do
        for line in tostring(read_file(root .. "\\" .. name .. ".txt") or ""):gmatch("[^\r\n]+") do
            local key, value = line:match("^([%w_]+)=(.*)$")
            if key and ({ INCLUDE = true, LIB = true, PATH = true })[key:upper()] then
                compiler_context.environment[key:upper()] = value
            end
        end
    end
    for _, name in ipairs({ "host.c", "host.def", "host.obj", "host.lib", "host.exp", "build.cmd", "build.log",
        "compiler.txt", "include.txt", "lib.txt", "path.txt" }) do
        os.remove(root .. "\\" .. name)
    end
    local converted, native_root = M.call("acp", root)
    local parent_converted, native_parent = M.call("acp", parent)
    local pid_ok, pid = M.call("pid")
    local binary = read_file(loaded_path)
    if converted and pid_ok and binary then
        M.call("write", native_root .. "\\owner", "luainstaller-windows-host-v1\npid=" .. pid
            .. "\nhash=" .. require("luainstaller.hash").sha256(binary) .. "\n")
        if parent_converted then pcall(cleanup_previous, native_parent, native_root) end
    end
    return loaded
end

local function u32(value)
    return string.char(value % 256, math.floor(value / 256) % 256,
        math.floor(value / 65536) % 256, math.floor(value / 16777216) % 256)
end

function M.call(operation, ...)
    local fields = { operation, ... }
    local data = { u32(#fields) }
    for _, value in ipairs(fields) do
        if type(value) ~= "string" or #value > 4294967295 then return false, "invalid native Windows argument" end
        data[#data + 1] = u32(#value)
        data[#data + 1] = value
    end
    local module, err = bootstrap()
    if not module then return false, err end
    return module.request(table.concat(data))
end

function M.compiler()
    local module, err = bootstrap()
    if not module then return nil, err end
    return compiler_context
end

function M.execute(executable, arguments, environment, timeout)
    local module, err = bootstrap()
    if not module then return false, err end
    local child_environment = {}
    for key, value in pairs(environment or {}) do child_environment[key] = value end
    -- Lua subprocesses can reuse the already-built module even when their
    -- PATH intentionally omits development tools (logging and discovery).
    local lua_child = false
    for _, value in ipairs(arguments) do
        if value == "-e" or value:match("%.lua$") then lua_child = true; break end
    end
    if lua_child then
        local converted, dll = M.call("acp", loaded_path)
        if not converted then return false, dll end
        child_environment.LUAI_WINDOWS_HOST_DLL = dll
        child_environment.LUAI_WINDOWS_HOST_ABI = _VERSION
        child_environment.LUAI_WINDOWS_HOST_ID = source_id
    end
    local fields = { executable, tostring(math.min(4294967294, math.max(0, math.floor((timeout or 0) * 1000)))),
        tostring(#arguments) }
    for _, value in ipairs(arguments) do fields[#fields + 1] = value end
    local keys = {}
    for key in pairs(child_environment) do keys[#keys + 1] = key end
    table.sort(keys)
    fields[#fields + 1] = tostring(#keys)
    for _, key in ipairs(keys) do fields[#fields + 1] = key; fields[#fields + 1] = child_environment[key] end
    return M.call("exec", (table.unpack or unpack)(fields))
end

return M
