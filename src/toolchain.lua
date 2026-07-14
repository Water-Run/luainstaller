--[[
Native compiler and Lua development-toolchain discovery for luainstaller.

Author:
    WaterRun
File:
    toolchain.lua
Date:
    2026-07-14
Updated:
    2026-07-14
]]

local compat = require("luainstaller.compat")
local fs = require("luainstaller.fs")
local path = require("luainstaller.path")
local platform = require("luainstaller.platform")
local process = require("luainstaller.process")
local result = require("luainstaller.result")

local M = {}

local makeError = result.error
local normalizePath = path.normalize
local shellQuote = process.shellQuote

local function trimmed(value)
    return (tostring(value or ""):gsub("%s+$", ""))
end

local function luaVersionInfo(configured)
    local current = configured or compat.luaVersion()
    local major = tonumber(current.major)
    local minor = tonumber(current.minor)
    if not major or not minor then
        major, minor = tostring(current.version or ""):match("Lua%s+(%d+)%.(%d+)")
        major, minor = tonumber(major), tonumber(minor)
    end
    if major ~= 5 or not minor or minor < 1 then
        return nil, makeError(
            "UnsupportedLuaVersionError",
            "A supported official Lua 5.1+ ABI is required",
            { lua_version = current.version }
        )
    end
    return {
        version = string.format("Lua %d.%d", major, minor),
        major = major,
        minor = minor,
        num = tonumber(current.num) or (major * 100 + minor),
        abi = current.abi or string.format("lua%d.%d", major, minor),
    }
end

local function versionMatches(value, lua_version)
    local expected = string.format("%d.%d", lua_version.major, lua_version.minor)
    value = trimmed(value)
    if value == expected then return true end
    local escaped = expected:gsub("%.", "%%.")
    return value:match("^" .. escaped .. "[%.%-%+][0-9A-Za-z%.%-%+]*$") ~= nil
end

local function safeFlagTokens(raw)
    local tokens = {}
    for token in tostring(raw or ""):gmatch("%S+") do
        if token:find("[\n\r;&|`$()<>]")
            or not token:match("^[%w%+%,%./=:_@%%%-]+$") then
            return nil, makeError("ToolchainError", "Toolchain flags contain unsafe characters", {
                token = token,
            })
        end
        tokens[#tokens + 1] = token:sub(1, 1) == "-" and token or shellQuote(token)
    end
    return tokens
end

local function commandAvailable(command)
    local ok = process.output(shellQuote(command) .. " --version")
    return ok == true
end

local function compilerFamily(command)
    local name = path.basename(command):lower()
    if name == "cl" or name == "cl.exe" then return "msvc" end
    if name:find("clang", 1, true) then return "clang" end
    if name:find("gcc", 1, true) or name == "cc" then return "gcc" end
    return "cc"
end

local function prefixFromInterpreter(interpreter)
    if type(interpreter) ~= "string" or interpreter == "" then return nil end
    local located = process.firstLine("command -v " .. shellQuote(interpreter))
    if not located or located:sub(1, 1) ~= "/" then return nil end
    return path.dirname(path.dirname(located))
end

local function regularFile(candidate)
    return candidate and fs.isRegularFile(candidate)
end

local function installedLibraryName(library_dir, names)
    for _, name in ipairs(names) do
        for _, extension in ipairs({ ".a", ".so", ".dylib" }) do
            if regularFile(library_dir .. "/lib" .. name .. extension) then
                return name
            end
        end
    end
    return nil
end

local function prefixCandidate(prefix, lua_version, source)
    if type(prefix) ~= "string" or prefix == "" then return nil end
    prefix = normalizePath(prefix)
    local version = string.format("%d.%d", lua_version.major, lua_version.minor)
    local include_candidates = {
        prefix .. "/include",
        prefix .. "/include/lua" .. version,
        prefix .. "/include/lua-" .. version,
        prefix .. "/include/lua" .. lua_version.major .. lua_version.minor,
    }
    local include_dir
    for _, candidate in ipairs(include_candidates) do
        if regularFile(candidate .. "/lua.h") then
            include_dir = candidate
            break
        end
    end
    if not include_dir then return nil end

    local library_dir = prefix .. "/lib"
    local link_names = {
        "lua" .. version,
        "lua-" .. version,
        "lua" .. lua_version.major .. lua_version.minor,
        "lua",
    }
    local installed_name = installedLibraryName(library_dir, link_names)
    if installed_name then link_names = { installed_name } end
    return {
        source = source,
        include_dir = include_dir,
        library_dir = library_dir,
        cflags = "-I" .. include_dir,
        libraries = link_names,
    }
end

local function luarocksCandidate(lua_version)
    if not commandAvailable("luarocks") then return nil end
    local include_ok, include_dir = process.output("luarocks config variables.LUA_INCDIR")
    local library_ok, library_dir = process.output("luarocks config variables.LUA_LIBDIR")
    local name_ok, library_name = process.output("luarocks config variables.LUA_LIBNAME")
    include_dir, library_dir, library_name = trimmed(include_dir), trimmed(library_dir), trimmed(library_name)
    if not include_ok or not regularFile(normalizePath(include_dir .. "/lua.h")) then return nil end
    if not library_ok or library_dir == "" then return nil end
    if not name_ok or library_name == "" then
        library_name = installedLibraryName(normalizePath(library_dir), {
            "lua" .. lua_version.major .. "." .. lua_version.minor,
            "lua-" .. lua_version.major .. "." .. lua_version.minor,
            "lua" .. lua_version.major .. lua_version.minor,
            "lua",
        }) or ("lua" .. lua_version.major .. lua_version.minor)
    end
    library_name = library_name:gsub("^lib", ""):gsub("%.[^.]+$", "")
    return {
        source = "luarocks",
        include_dir = normalizePath(include_dir),
        library_dir = normalizePath(library_dir),
        cflags = "-I" .. normalizePath(include_dir),
        libraries = { library_name },
    }
end

local function pkgConfigCandidates(lua_version)
    local version = string.format("%d.%d", lua_version.major, lua_version.minor)
    return {
        "lua" .. version,
        "lua-" .. version,
        "lua" .. lua_version.major .. lua_version.minor,
        "lua",
    }
end

local function pkgConfigCandidate(lua_version)
    if not commandAvailable("pkg-config") then return nil end
    for _, module_name in ipairs(pkgConfigCandidates(lua_version)) do
        local version_ok, module_version = process.output(
            "pkg-config --modversion " .. shellQuote(module_name)
        )
        if version_ok and versionMatches(module_version, lua_version) then
            local flags_ok, flags = process.output(
                "pkg-config --cflags --libs " .. shellQuote(module_name)
            )
            if flags_ok then
                return {
                    source = "pkg-config",
                    pkg_config_module = module_name,
                    pkg_config_version = trimmed(module_version),
                    flags = trimmed(flags),
                }
            end
        end
    end
    return nil
end

local function probeSource(lua_version)
    local source = [[
#include <stdio.h>
#include <string.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#if !defined(LUA_VERSION_NUM) || LUA_VERSION_NUM != @LUA_VERSION_NUM@
#error "luainstaller toolchain Lua ABI mismatch"
#endif

int main(void) {
    lua_State *state = luaL_newstate();
    const char *version;
    int matches;
    if (!state) return 70;
    luaL_openlibs(state);
    lua_getglobal(state, "_VERSION");
    version = lua_tostring(state, -1);
    matches = version != NULL && strcmp(version, "@LUA_VERSION@") == 0;
    if (!matches) {
        fprintf(stderr, "expected @LUA_VERSION@, got %s\n", version ? version : "unknown");
    }
    lua_close(state);
    return matches ? 0 : 42;
}
]]
    source = source:gsub("@LUA_VERSION_NUM@", tostring(lua_version.num))
    source = source:gsub("@LUA_VERSION@", lua_version.version)
    return source
end

local function makeProbeDirectory()
    local ok, output = process.output("mktemp -d /tmp/luainstaller-toolchain-XXXXXX")
    local directory = trimmed(output)
    if not ok or not directory:match("^/tmp/luainstaller%-toolchain%-%w+$") then
        return nil, makeError("FilesystemError", "Cannot create a private toolchain probe directory", {
            output = output,
        })
    end
    return normalizePath(directory)
end

local function cleanupProbeDirectory(directory)
    if not directory or not directory:match("^/tmp/luainstaller%-toolchain%-%w+$") then
        return false
    end
    local ok = process.output("rm -rf " .. shellQuote(directory))
    return ok == true
end

local function candidateFlags(candidate)
    if candidate.flags then return safeFlagTokens(candidate.flags) end
    local flags = { "-I" .. candidate.include_dir }
    if candidate.library_dir and candidate.library_dir ~= "" then
        flags[#flags + 1] = "-L" .. candidate.library_dir
    end
    for _, library in ipairs(candidate.libraries or {}) do
        local copied = {}
        for _, value in ipairs(flags) do copied[#copied + 1] = value end
        copied[#copied + 1] = "-l" .. library
        copied[#copied + 1] = "-lm"
        local safe, safe_err = safeFlagTokens(table.concat(copied, " "))
        if safe then return safe end
        if safe_err then return nil, safe_err end
    end
    return safeFlagTokens(table.concat(flags, " "))
end

local function verifyCandidate(config, candidate)
    local directory, directory_err = makeProbeDirectory()
    if not directory then return nil, directory_err end
    local source_path = normalizePath(directory .. "/probe.c")
    local executable_path = normalizePath(directory .. "/probe")
    local wrote, write_err = fs.writeFile(source_path, probeSource(config.lua_version))
    if not wrote then
        cleanupProbeDirectory(directory)
        return nil, makeError("FilesystemError", "Cannot write the toolchain probe", {
            path = source_path,
            cause = write_err,
        })
    end
    local flags, flags_err = candidateFlags(candidate)
    if not flags then
        cleanupProbeDirectory(directory)
        return nil, flags_err
    end
    local command = table.concat({
        shellQuote(config.cc),
        "-std=c11",
        "-Wall",
        "-Wextra",
        "-Werror",
        "-pedantic",
        shellQuote(source_path),
        "-o",
        shellQuote(executable_path),
        table.concat(flags, " "),
    }, " ")
    local compiled, compile_output = process.output(command)
    if not compiled then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "Lua development toolchain probe did not compile", {
            command = command,
            output = compile_output,
            source = candidate.source,
        })
    end
    local run_command = shellQuote(executable_path)
    if config.host.os ~= "macos" and candidate.library_dir and candidate.library_dir ~= "" then
        run_command = "LD_LIBRARY_PATH=" .. shellQuote(candidate.library_dir) .. " " .. run_command
    end
    local ran, run_output = process.output(run_command)
    local cleaned = cleanupProbeDirectory(directory)
    if not ran then
        return nil, makeError("ToolchainError", "Linked Lua runtime probe did not match the selected ABI", {
            command = run_command,
            output = run_output,
            expected = config.lua_version.version,
        })
    end
    if not cleaned then
        return nil, makeError("FilesystemError", "Cannot remove the completed toolchain probe", {
            path = directory,
        })
    end
    config.cflags = candidate.cflags
    config.link_args = flags
    config.include_dir = candidate.include_dir
    config.library_dir = candidate.library_dir
    config.pkg_config_module = candidate.pkg_config_module
    config.discovery_source = candidate.source
    return config
end

function M.resolve(opts)
    opts = opts or {}
    local profile, profile_err = platform.profile({
        target_os = opts.target_os,
        target_arch = opts.target_arch,
        lua_prefix = opts.lua_prefix,
    })
    if not profile then return nil, profile_err end
    local lua_version, version_err = luaVersionInfo(opts.lua_version)
    if not lua_version then return nil, version_err end
    if profile.target_os == "windows" then
        return nil, makeError(
            "ToolchainError",
            "Native Windows toolchain discovery requires Windows compiler metadata",
            { host = profile.target_os, lua_abi = lua_version.abi }
        )
    end

    local candidates = {}
    local explicit = prefixCandidate(
        opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        lua_version,
        "explicit-prefix"
    )
    if explicit then candidates[#candidates + 1] = explicit end
    local active = prefixCandidate(
        prefixFromInterpreter(opts.lua or os.getenv("LUAI_LUA") or (arg and arg[-1])),
        lua_version,
        "active-lua"
    )
    if active then candidates[#candidates + 1] = active end
    local rock = luarocksCandidate(lua_version)
    if rock then candidates[#candidates + 1] = rock end
    local pkg = pkgConfigCandidate(lua_version)
    if pkg then candidates[#candidates + 1] = pkg end

    local cc = opts.cc or os.getenv("LUAI_CC") or os.getenv("CC") or "cc"
    if #candidates == 0 then
        return nil, makeError("ToolchainError", "No Lua development metadata matches the selected ABI", {
            lua_abi = lua_version.abi,
        })
    end
    if not commandAvailable(cc) then
        return nil, makeError("ToolchainError", "A native C compiler is required", {
            compiler = cc,
        })
    end
    local config = {
        host = platform.detectHost(),
        profile = profile,
        lua_version = lua_version,
        cc = cc,
        compiler_family = compilerFamily(cc),
        executable_suffix = profile.executable_suffix,
        native_extensions = profile.native_extensions,
    }

    local failures = {}
    for _, candidate in ipairs(candidates) do
        local verified, verify_err = verifyCandidate(config, candidate)
        if verified then return verified end
        failures[#failures + 1] = verify_err.error
    end
    return nil, makeError(
        "ToolchainError",
        "Cannot resolve a verified native Lua development toolchain for the linked Lua runtime",
        {
        lua_abi = lua_version.abi,
        compiler = cc,
        failures = failures,
        }
    )
end

return M
