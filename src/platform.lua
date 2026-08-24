--[[
Platform profile helpers for luainstaller.

Author:
    WaterRun
File:
    platform.lua
Date:
    2026-06-21
Updated:
    2026-07-18
]]

local process = require("luainstaller.process")
local result = require("luainstaller.result")

local M = {}

local PATH_SEP = package.config:sub(1, 1)

function M.normalizeArch(value)
    local arch = tostring(value or "unknown"):lower()
    if arch == "amd64" or arch == "x64" or arch == "x86_64" then
        return "x86_64"
    end
    if arch == "aarch64" or arch == "arm64" then
        return "arm64"
    end
    if arch == "x86" or arch:match("^i[3-6]86$") then
        return "x86"
    end
    if arch == "arm" or arch == "armhf" or arch == "armel"
        or arch:match("^armv[5-8]") then
        return "arm"
    end
    if arch == "riscv64gc" then return "riscv64" end
    if arch == "ppc64le" then return "powerpc64le" end
    if arch == "ppc64" then return "powerpc64" end
    if arch == "ppc" then return "powerpc" end
    return arch ~= "" and arch or "unknown"
end

local function environmentValue(environment, name)
    if type(environment) == "table" then return environment[name] end
    if type(environment) == "function" then return environment(name) end
    return os.getenv(name)
end

local function isAndroidEnvironment(environment)
    local prefix = tostring(
        environmentValue(environment, "TERMUX__PREFIX")
            or environmentValue(environment, "PREFIX")
            or environmentValue(environment, "TERMUX_PREFIX")
            or ""
    )
    return environmentValue(environment, "TERMUX_VERSION") ~= nil
        or environmentValue(environment, "ANDROID_ROOT") ~= nil
        or prefix:find("com.termux/files/usr", 1, true) ~= nil
end

function M.normalizeOS(value, environment)
    local uname = tostring(value or "")
    if uname == "Linux" then
        return isAndroidEnvironment(environment) and "android" or "linux"
    end
    if uname == "Darwin" then return "macos" end
    if uname == "Windows_NT" then return "windows" end
    local normalized = uname:lower():gsub("[^%w]+", "")
    return normalized ~= "" and normalized or "unknown"
end

local function runningElfBits()
    local executable = arg and arg[-1]
    if type(executable) ~= "string" or executable == "" then return nil end
    if not executable:find("/", 1, true) then
        executable = process.firstLine("command -v " .. process.quote(executable))
    end
    if type(executable) ~= "string" or executable == "" then return nil end
    local opened, handle = pcall(io.open, executable, "rb")
    if not opened or not handle then return nil end
    local read_ok, header = pcall(handle.read, handle, 5)
    pcall(handle.close, handle)
    if not read_ok or type(header) ~= "string" or #header < 5
        or header:sub(1, 4) ~= "\127ELF" then
        return nil
    end
    if header:byte(5) == 1 then return 32 end
    if header:byte(5) == 2 then return 64 end
    return nil
end

function M.detectHost()
    if PATH_SEP == "\\" then
        return {
            os = "windows",
            arch = M.normalizeArch(
                -- PROCESSOR_ARCHITECTURE describes this process environment;
                -- PROCESSOR_ARCHITEW6432 describes the underlying OS and
                -- would misclassify a native 32-bit Lua/toolchain as x64.
                os.getenv("PROCESSOR_ARCHITECTURE")
                    or os.getenv("PROCESSOR_ARCHITEW6432")
                    or "unknown"
            ),
        }
    end

    local uname_s = process.firstLine("uname -s")
    local uname_m = process.firstLine("uname -m")
    local normalized_arch = M.normalizeArch(uname_m)
    if normalized_arch == "x86_64" or normalized_arch == "arm64" then
        local process_bits = runningElfBits()
            or tonumber(process.firstLine("getconf LONG_BIT 2>/dev/null"))
        if process_bits == 32 then
            normalized_arch = normalized_arch == "x86_64" and "x86" or "arm"
        end
    end
    local os_name = M.normalizeOS(uname_s)
    return {
        os = os_name,
        arch = normalized_arch,
    }
end

function M.profile(opts)
    opts = opts or {}
    local host = opts.host or M.detectHost()
    local target_os = opts.target_os
    if target_os == nil or target_os == "" then
        target_os = host.os
    end
    local host_arch = M.normalizeArch(host.arch)
    local target_arch = M.normalizeArch(opts.target_arch or host_arch)
    if target_os ~= host.os or target_arch ~= host_arch then
        return nil, result.error(
            "UnsupportedPlatformError",
            "luainstaller only builds for the native host OS and architecture",
            {
                host_os = host.os,
                host_arch = host_arch,
                target_os = target_os,
                target_arch = target_arch,
            }
        )
    end
    if target_os == "windows" then
        return {
            target_os = target_os,
            target_arch = target_arch,
            launcher_profile = "windows-shared-lua",
            executable_suffix = ".exe",
            native_extensions = { ".dll" },
            loader_rpath = nil,
            runtime_library_path_var = nil,
            system_libraries = {},
            supported_link_modes = { "shared" },
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    if target_os == "macos" then
        return {
            target_os = "macos",
            target_arch = target_arch,
            launcher_profile = "static-lua",
            executable_suffix = "",
            native_extensions = { ".so", ".dylib" },
            loader_rpath = "@loader_path/.luai/native",
            runtime_library_path_var = "DYLD_LIBRARY_PATH",
            system_libraries = { "-lm" },
            supported_link_modes = { "static", "shared" },
            lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        }
    end
    local system_libraries = { "-lm" }
    -- Linux and Android expose dlopen(3) through libdl.  The BSDs expose it
    -- from libc, so adding -ldl there makes an otherwise valid Lua toolchain
    -- fail before the capability probe can run.
    if target_os == "linux" or target_os == "android" then
        system_libraries[#system_libraries + 1] = "-ldl"
    end
    return {
        target_os = target_os,
        target_arch = target_arch,
        launcher_profile = "shared-lua",
        executable_suffix = "",
        native_extensions = { ".so" },
        loader_rpath = "$ORIGIN/.luai/native",
        runtime_library_path_var = "LD_LIBRARY_PATH",
        system_libraries = system_libraries,
        supported_link_modes = { "shared", "static" },
        lua_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
    }
end

return M
