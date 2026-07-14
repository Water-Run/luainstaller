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

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local makeError = result.error
local normalizePath = path.normalize

local function trimmed(value)
    return (tostring(value or ""):gsub("%s+$", ""))
end

local function copyList(values)
    local copied = {}
    for _, value in ipairs(values or {}) do copied[#copied + 1] = value end
    return copied
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
        tokens[#tokens + 1] = token
    end
    return tokens
end

local function compilerFamily(command)
    local name = path.basename(command):lower()
    if name == "cl" or name == "cl.exe" then return "msvc" end
    if name:find("clang", 1, true) then return "clang" end
    if name:find("gcc", 1, true) or name == "cc" then return "gcc" end
    return "cc"
end

local function commandAvailable(command, family, environment)
    local argument = family == "msvc" and "/?" or "--version"
    local ok = process.outputCommand(command, { argument }, environment)
    return ok == true
end

local function regularFile(candidate)
    return type(candidate) == "string" and fs.pathType(candidate) == "file"
end

local function windowsSystemPath(name)
    local root = os.getenv("SystemRoot") or os.getenv("WINDIR")
    if type(root) ~= "string" or not root:match("^%a:[/\\]")
        or root:find('[%c"%%!%^&|<>]') then
        return nil
    end
    local candidate = normalizePath(root .. "/System32/" .. name)
    return regularFile(candidate) and candidate or nil
end

local function whereProgram(name, environment)
    local where = windowsSystemPath("where.exe")
    if not where then return nil end
    local ok, output = process.outputCommand(where, { name }, environment)
    if not ok then return nil end
    for line in tostring(output):gmatch("[^\r\n]+") do
        local candidate = trimmed(line)
        if regularFile(candidate) then return normalizePath(candidate) end
    end
    return nil
end

local function discoverMsvc()
    local program_files = os.getenv("ProgramFiles(x86)") or os.getenv("ProgramFiles")
    local vswhere = program_files and normalizePath(
        program_files .. "/Microsoft Visual Studio/Installer/vswhere.exe"
    ) or nil
    if not regularFile(vswhere) then return nil, "vswhere.exe was not found" end
    local ok, output = process.outputCommand(vswhere, {
        "-latest", "-prerelease", "-products", "*",
        "-requires", "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
        "-property", "installationPath",
    })
    local installation = ok and trimmed(output):match("[^\r\n]+") or nil
    if not installation or installation:find('[\r\n"&|<>]') then
        return nil, "Visual Studio installation discovery returned no safe path"
    end
    local version_path = normalizePath(
        installation .. "/VC/Auxiliary/Build/Microsoft.VCToolsVersion.default.txt"
    )
    local version = regularFile(version_path) and trimmed(fs.readFile(version_path)) or nil
    if not version or not version:match("^%d+%.%d+%.%d+$") then
        return nil, "Visual C++ tools version metadata is unavailable"
    end
    local tools_root = normalizePath(installation .. "/VC/Tools/MSVC/" .. version)
    local binary_dir = normalizePath(tools_root .. "/bin/Hostx64/x64")
    local cc = normalizePath(binary_dir .. "/cl.exe")
    local librarian = normalizePath(binary_dir .. "/lib.exe")
    local dumpbin = normalizePath(binary_dir .. "/dumpbin.exe")
    if not regularFile(cc) or not regularFile(librarian) or not regularFile(dumpbin) then
        return nil, "Visual C++ x64 compiler tools are incomplete"
    end
    local sdk_ok, sdk_output = process.outputPowerShell(table.concat({
        "$Root=[IO.Path]::Combine(${env:ProgramFiles(x86)},'Windows Kits','10','Include');",
        "$Version=Get-ChildItem -LiteralPath $Root -Directory -ErrorAction Stop|",
        "Where-Object{Test-Path -LiteralPath ([IO.Path]::Combine($_.FullName,'um','Windows.h'))}|",
        "Sort-Object Name -Descending|Select-Object -First 1;",
        "if($null -eq $Version){exit 1};[Console]::Write($Version.Name)",
    }))
    local sdk_version = sdk_ok and trimmed(sdk_output) or nil
    if not sdk_version or not sdk_version:match("^%d+%.%d+%.%d+%.%d+$") then
        return nil, "Windows SDK headers are unavailable"
    end
    local kits_root = normalizePath(program_files .. "/Windows Kits/10")
    local include_root = normalizePath(kits_root .. "/Include/" .. sdk_version)
    local library_root = normalizePath(kits_root .. "/Lib/" .. sdk_version)
    local environment = {
        INCLUDE = table.concat({
            tools_root .. "/include",
            include_root .. "/ucrt",
            include_root .. "/shared",
            include_root .. "/um",
            include_root .. "/winrt",
        }, ";"):gsub("/", "\\"),
        LIB = table.concat({
            tools_root .. "/lib/x64",
            library_root .. "/ucrt/x64",
            library_root .. "/um/x64",
        }, ";"):gsub("/", "\\"),
        PATH = (binary_dir .. ";" .. tostring(os.getenv("PATH") or "")):gsub("/", "\\"),
    }
    return {
        cc = cc,
        compiler_family = "msvc",
        environment = environment,
        librarian = librarian,
        dumpbin = dumpbin,
        discovery_source = "visual-studio",
    }
end

local function discoverCompiler(opts, host)
    local configured = opts.cc or os.getenv("LUAI_CC") or os.getenv("CC")
    if configured and configured ~= "" then
        local family = compilerFamily(configured)
        if commandAvailable(configured, family) then
            return { cc = configured, compiler_family = family, environment = {} }
        end
        return nil, makeError("ToolchainError", "The configured native C compiler is unavailable", {
            compiler = configured,
        })
    end
    if host.os == "windows" then
        for _, name in ipairs({ "cl.exe", "clang.exe", "gcc.exe" }) do
            local family = compilerFamily(name)
            if commandAvailable(name, family) then
                return { cc = name, compiler_family = family, environment = {} }
            end
        end
        local msvc, discovery_err = discoverMsvc()
        if msvc then return msvc end
        return nil, makeError("ToolchainError", "A native Windows C compiler is required", {
            cause = discovery_err,
        })
    end
    local cc = "cc"
    if not commandAvailable(cc, compilerFamily(cc)) then
        return nil, makeError("ToolchainError", "A native C compiler is required", { compiler = cc })
    end
    return { cc = cc, compiler_family = compilerFamily(cc), environment = {} }
end

local function prefixFromInterpreter(interpreter)
    if type(interpreter) ~= "string" or interpreter == "" then return nil end
    local located = interpreter
    if not regularFile(located) then
        if IS_WINDOWS then
            located = whereProgram(interpreter, {})
        else
            local ok, output = process.outputCommand("/bin/sh", {
                "-c", "command -v \"$1\"", "sh", interpreter,
            })
            located = ok and trimmed(output):match("[^\r\n]+") or nil
        end
    end
    if not regularFile(located) then return nil end
    if IS_WINDOWS then return path.dirname(normalizePath(located)) end
    return path.dirname(path.dirname(normalizePath(located)))
end

local function luaNames(lua_version)
    local dotted = string.format("lua%d.%d", lua_version.major, lua_version.minor)
    local compact = string.format("lua%d%d", lua_version.major, lua_version.minor)
    return { dotted, "lua-" .. lua_version.major .. "." .. lua_version.minor, compact, "lua" }
end

local function findFirst(paths)
    for _, candidate in ipairs(paths) do
        if regularFile(candidate) then return normalizePath(candidate) end
    end
    return nil
end

local function prefixCandidate(prefix, lua_version, source, config)
    if type(prefix) ~= "string" or prefix == "" then return nil end
    prefix = normalizePath(prefix)
    local version = string.format("%d.%d", lua_version.major, lua_version.minor)
    local include_dir
    for _, candidate in ipairs({
        prefix .. "/include",
        prefix .. "/include/lua" .. version,
        prefix .. "/include/lua-" .. version,
        prefix .. "/include/lua" .. lua_version.major .. lua_version.minor,
        prefix,
    }) do
        if regularFile(candidate .. "/lua.h") then include_dir = candidate break end
    end
    if not include_dir then return nil end

    local names = luaNames(lua_version)
    local library_paths = {}
    local extensions
    if config.host.os == "windows" then
        extensions = config.compiler_family == "msvc" and { ".lib", ".a" } or { ".a", ".lib" }
    elseif config.host.os == "macos" then
        extensions = { ".a", ".dylib", ".so" }
    else
        extensions = { ".so", ".a", ".dylib" }
    end
    for _, directory in ipairs({ prefix .. "/lib", prefix }) do
        for _, name in ipairs(names) do
            for _, extension in ipairs(extensions) do
                library_paths[#library_paths + 1] = directory .. "/lib" .. name .. extension
                library_paths[#library_paths + 1] = directory .. "/" .. name .. extension
            end
        end
    end
    local library_path = findFirst(library_paths)

    local runtime_path
    if config.host.os == "windows" then
        local runtime_paths = {}
        for _, directory in ipairs({ prefix .. "/bin", prefix }) do
            for _, name in ipairs(names) do
                runtime_paths[#runtime_paths + 1] = directory .. "/" .. name .. ".dll"
            end
        end
        runtime_path = findFirst(runtime_paths)
        if not runtime_path then return nil end
    elseif not library_path then
        return nil
    end
    return {
        source = source,
        prefix = prefix,
        include_dir = normalizePath(include_dir),
        library_dir = library_path and path.dirname(library_path) or nil,
        library_path = library_path,
        runtime_path = runtime_path,
    }
end

local function commandConfigValue(name)
    local ok, output = process.outputCommand("luarocks", { "config", "variables." .. name })
    return ok and trimmed(output) or nil
end

local function luarocksCandidate(lua_version, config)
    if not commandAvailable("luarocks", "cc") then return nil end
    local include_dir = commandConfigValue("LUA_INCDIR")
    local library_dir = commandConfigValue("LUA_LIBDIR")
    local library_name = commandConfigValue("LUA_LIBNAME")
    if not include_dir or not regularFile(normalizePath(include_dir .. "/lua.h"))
        or not library_dir then
        return nil
    end
    local prefix = path.dirname(normalizePath(include_dir))
    local candidate = prefixCandidate(prefix, lua_version, "luarocks", config)
    if candidate then return candidate end
    local names = library_name and { library_name:gsub("^lib", ""):gsub("%.[^.]+$", "") }
        or luaNames(lua_version)
    local paths = {}
    for _, name in ipairs(names) do
        for _, extension in ipairs({ ".lib", ".a", ".so", ".dylib" }) do
            paths[#paths + 1] = normalizePath(library_dir .. "/lib" .. name .. extension)
            paths[#paths + 1] = normalizePath(library_dir .. "/" .. name .. extension)
        end
    end
    local library_path = findFirst(paths)
    if not library_path then return nil end
    return {
        source = "luarocks",
        include_dir = normalizePath(include_dir),
        library_dir = normalizePath(library_dir),
        library_path = library_path,
    }
end

local function pkgConfigCandidate(lua_version)
    if not commandAvailable("pkg-config", "cc") then return nil end
    for _, module_name in ipairs(luaNames(lua_version)) do
        local version_ok, module_version = process.outputCommand(
            "pkg-config", { "--modversion", module_name }
        )
        if version_ok and versionMatches(module_version, lua_version) then
            local flags_ok, flags = process.outputCommand(
                "pkg-config", { "--cflags", "--libs", module_name }
            )
            local tokens, token_err = flags_ok and safeFlagTokens(trimmed(flags)) or nil
            if tokens then
                local include_dir
                local library_dir
                for _, token in ipairs(tokens) do
                    include_dir = include_dir or token:match("^-I(.+)$")
                    library_dir = library_dir or token:match("^-L(.+)$")
                end
                return {
                    source = "pkg-config",
                    pkg_config_module = module_name,
                    pkg_config_version = trimmed(module_version),
                    flags = tokens,
                    include_dir = include_dir and normalizePath(include_dir) or nil,
                    library_dir = library_dir and normalizePath(library_dir) or nil,
                }
            end
            if token_err then return nil end
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
    if (!matches) fprintf(stderr, "expected @LUA_VERSION@, got %s\n", version ? version : "unknown");
    lua_close(state);
    return matches ? 0 : 42;
}
]]
    return (source:gsub("@LUA_VERSION_NUM@", tostring(lua_version.num))
        :gsub("@LUA_VERSION@", lua_version.version))
end

local function makeProbeDirectory()
    local directory, directory_err = fs.makePrivateDirectory("toolchain")
    if not directory then
        return nil, makeError("FilesystemError", "Cannot create a private toolchain probe directory", {
            cause = directory_err,
        })
    end
    return normalizePath(directory)
end

local function cleanupProbeDirectory(directory)
    return directory and fs.removeTree(directory) == true
end

local function candidateLinkArgs(config, candidate)
    if candidate.flags then return copyList(candidate.flags) end
    local arguments = {}
    if candidate.library_path then
        local extension = candidate.library_path:lower():match("(%.[^.]+)$")
        if config.compiler_family == "msvc" then
            if extension == ".lib" then arguments[#arguments + 1] = candidate.library_path end
        else
            arguments[#arguments + 1] = candidate.library_path
        end
    end
    if config.host.os ~= "windows" then
        arguments[#arguments + 1] = "-lm"
        if config.host.os ~= "macos" then arguments[#arguments + 1] = "-ldl" end
    end
    return arguments
end

local function generateMsvcImportLibrary(config, work_dir)
    local output_path = normalizePath(work_dir .. "/lua-import.lib")
    if regularFile(output_path) then return output_path end
    if not config.runtime_path or not config.dumpbin or not config.librarian then
        return nil, makeError("ToolchainError", "MSVC requires a Lua import library or DLL export tools")
    end
    local ok, output = process.outputCommand(
        config.dumpbin,
        { "/nologo", "/exports", config.runtime_path },
        config.environment
    )
    if not ok then
        return nil, makeError("ToolchainError", "Cannot inspect Lua DLL exports", { output = output })
    end
    local exports = {}
    local seen = {}
    for line in tostring(output):gmatch("[^\r\n]+") do
        local name = line:match("^%s*%d+%s+[0-9A-Fa-f]+%s+[0-9A-Fa-f]+%s+([_%a][_%w@?]*)")
        if name and not seen[name] then seen[name] = true exports[#exports + 1] = name end
    end
    table.sort(exports)
    if #exports == 0 then
        return nil, makeError("ToolchainError", "Lua DLL has no usable exported C symbols")
    end
    local definition = { "LIBRARY " .. path.basename(config.runtime_path), "EXPORTS" }
    for _, name in ipairs(exports) do definition[#definition + 1] = "    " .. name end
    local definition_path = normalizePath(work_dir .. "/lua-import.def")
    local wrote, write_err = fs.writeFile(definition_path, table.concat(definition, "\n") .. "\n")
    if not wrote then
        return nil, makeError("FilesystemError", "Cannot write Lua import definition", {
            path = definition_path,
            cause = write_err,
        })
    end
    local made, make_output = process.outputCommand(config.librarian, {
        "/nologo",
        "/def:" .. definition_path:gsub("/", "\\"),
        "/out:" .. output_path:gsub("/", "\\"),
        config.host.arch == "x86" and "/machine:X86" or "/machine:X64",
    }, config.environment)
    if not made or not regularFile(output_path) then
        return nil, makeError("ToolchainError", "Cannot generate the Lua import library", {
            output = make_output,
        })
    end
    return output_path
end

function M.compile(config, source_path, output_path, opts)
    opts = opts or {}
    local arguments = {}
    if config.compiler_family == "msvc" then
        for _, value in ipairs({ "/nologo", "/std:c11", "/W4", "/WX" }) do
            arguments[#arguments + 1] = value
        end
        local object_dir = normalizePath(opts.work_dir or path.dirname(output_path))
        local object_name = path.basename(source_path):gsub("%.[^%.]+$", "") .. ".obj"
        arguments[#arguments + 1] = "/I" .. config.include_dir:gsub("/", "\\")
        arguments[#arguments + 1] = source_path:gsub("/", "\\")
        arguments[#arguments + 1] = "/Fo" .. normalizePath(
            object_dir .. "/" .. object_name
        ):gsub("/", "\\")
        arguments[#arguments + 1] = "/Fe:" .. output_path:gsub("/", "\\")
        local linked = false
        for _, value in ipairs(config.link_args or {}) do
            arguments[#arguments + 1] = value:gsub("/", "\\")
            linked = true
        end
        if not linked then
            local import, import_err = generateMsvcImportLibrary(
                config,
                normalizePath(opts.work_dir or path.dirname(output_path))
            )
            if not import then return false, import_err.error.message, nil, import_err end
            arguments[#arguments + 1] = import:gsub("/", "\\")
        end
        arguments[#arguments + 1] = "/link"
        arguments[#arguments + 1] = "/INCREMENTAL:NO"
    else
        for _, value in ipairs({ "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic" }) do
            arguments[#arguments + 1] = value
        end
        if config.include_dir then arguments[#arguments + 1] = "-I" .. config.include_dir end
        arguments[#arguments + 1] = source_path
        arguments[#arguments + 1] = "-o"
        arguments[#arguments + 1] = output_path
        if opts.rpath and opts.rpath ~= "" then
            arguments[#arguments + 1] = "-Wl,-rpath," .. opts.rpath
        end
        for _, value in ipairs(config.link_args or {}) do arguments[#arguments + 1] = value end
    end
    local ok, output = process.outputCommand(config.cc, arguments, config.environment)
    local descriptor = process.command(config.cc, arguments)
    return ok, output, descriptor
end

local function findLinkedRuntime(config, executable)
    if config.host.os == "windows" then return config.runtime_path end
    local tool = config.host.os == "macos" and "otool" or "ldd"
    local arguments = config.host.os == "macos" and { "-L", executable } or { executable }
    local ok, output = process.outputCommand(tool, arguments)
    if not ok then return nil, output end
    for line in tostring(output):gmatch("[^\r\n]+") do
        local candidate
        if config.host.os == "macos" then
            candidate = line:match("^%s*(/[^%s]*[Ll]ua[^%s]*%.dylib)")
        else
            candidate = line:match("=>%s+([^%s]+)") or line:match("^%s*(/[^%s]+)")
            if candidate and not path.basename(candidate):lower():find("lua", 1, true) then
                candidate = nil
            end
        end
        if candidate and regularFile(candidate) then return normalizePath(candidate) end
    end
    return nil, output
end

local function verifyCandidate(config, candidate)
    local directory, directory_err = makeProbeDirectory()
    if not directory then return nil, directory_err end
    local source_path = normalizePath(directory .. "/probe.c")
    local executable_path = normalizePath(directory .. "/probe" .. config.executable_suffix)
    local wrote, write_err = fs.writeFile(source_path, probeSource(config.lua_version))
    if not wrote then
        cleanupProbeDirectory(directory)
        return nil, makeError("FilesystemError", "Cannot write the toolchain probe", {
            path = source_path,
            cause = write_err,
        })
    end
    config.include_dir = candidate.include_dir
    config.library_dir = candidate.library_dir
    config.library_path = candidate.library_path
    config.runtime_path = candidate.runtime_path
    config.link_args = candidateLinkArgs(config, candidate)
    config.pkg_config_module = candidate.pkg_config_module
    config.discovery_source = candidate.source
    local compiled, compile_output, command = M.compile(config, source_path, executable_path, {
        work_dir = directory,
    })
    if not compiled then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "Lua development toolchain probe did not compile", {
            command = command,
            output = compile_output,
            source = candidate.source,
        })
    end
    if config.host.os == "windows" and config.runtime_path then
        local runtime_copy = normalizePath(directory .. "/" .. path.basename(config.runtime_path))
        if runtime_copy ~= normalizePath(config.runtime_path) then
            local copied, copy_err = fs.copyFile(config.runtime_path, runtime_copy)
            if not copied then
                cleanupProbeDirectory(directory)
                return nil, makeError("FilesystemError", "Cannot stage the Lua runtime probe DLL", {
                    cause = copy_err,
                })
            end
        end
    end
    local environment = {}
    if config.host.os == "linux" and config.library_dir then
        environment.LD_LIBRARY_PATH = config.library_dir
    elseif config.host.os == "macos" and config.library_dir then
        environment.DYLD_LIBRARY_PATH = config.library_dir
    end
    local ran, run_output = process.outputCommand(executable_path, {}, environment)
    if not ran then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "Linked Lua runtime probe did not match the selected ABI", {
            output = run_output,
            expected = config.lua_version.version,
        })
    end
    local runtime_path, runtime_output = findLinkedRuntime(config, executable_path)
    local static_candidate = candidate.library_path
        and candidate.library_path:lower():match("%.a$") ~= nil
    if not runtime_path and not static_candidate then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "Cannot identify the linked Lua runtime", {
            output = runtime_output,
        })
    end
    if runtime_path then config.runtime_path = runtime_path end
    config.link_mode = runtime_path and "shared" or "static"
    config.static_library_path = not runtime_path and candidate.library_path or nil
    if not cleanupProbeDirectory(directory) then
        return nil, makeError("FilesystemError", "Cannot remove the completed toolchain probe", {
            path = directory,
        })
    end
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
    local host = platform.detectHost()
    local configured_cc = opts.cc or os.getenv("LUAI_CC") or os.getenv("CC")
    local config = {
        host = host,
        profile = profile,
        lua_version = lua_version,
        compiler_family = configured_cc and compilerFamily(configured_cc)
            or (host.os == "windows" and "msvc" or "cc"),
        executable_suffix = profile.executable_suffix,
        native_extensions = profile.native_extensions,
    }

    local candidates = {}
    local explicit = prefixCandidate(
        opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX"),
        lua_version,
        "explicit-prefix",
        config
    )
    if explicit then candidates[#candidates + 1] = explicit end
    local active = prefixCandidate(
        prefixFromInterpreter(opts.lua or os.getenv("LUAI_LUA") or (arg and arg[-1])),
        lua_version,
        "active-lua",
        config
    )
    if active then candidates[#candidates + 1] = active end
    local rock = luarocksCandidate(lua_version, config)
    if rock then candidates[#candidates + 1] = rock end
    if host.os ~= "windows" then
        local pkg = pkgConfigCandidate(lua_version)
        if pkg then candidates[#candidates + 1] = pkg end
    end
    if #candidates == 0 then
        return nil, makeError("ToolchainError", "No Lua development metadata matches the selected ABI", {
            lua_abi = lua_version.abi,
        })
    end
    local compiler, compiler_err = discoverCompiler(opts, host)
    if not compiler then return nil, compiler_err end
    config.cc = compiler.cc
    config.compiler_family = compiler.compiler_family
    config.environment = compiler.environment or {}
    config.librarian = compiler.librarian
    config.dumpbin = compiler.dumpbin

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
            compiler = config.cc,
            failures = failures,
        }
    )
end

return M
