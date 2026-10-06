--[[
Native compiler and Lua runtime discovery for luainstaller.

Author:
    WaterRun
File:
    toolchain.lua
Date:
Updated:
    2026-10-06
]]

local compat = require("luainstaller.compat")
local fs = require("luainstaller.fs")
local native_profile = require("luainstaller.native_profile")
local path = require("luainstaller.path")
local platform = require("luainstaller.platform")
local process = require("luainstaller.process")
local result = require("luainstaller.result")

local M = {}

local IS_WINDOWS = package.config:sub(1, 1) == "\\"
local makeError = result.error
local normalizePath = path.normalize

-- External commands must not hang a build forever (compilers waiting on
-- stdin or license servers are the classic case). LUAI_CMD_TIMEOUT overrides
-- the compile default; probe runs keep a tighter bound.
local COMPILE_TIMEOUT_SECONDS = 900
local PROBE_TIMEOUT_SECONDS = 120
-- VS 2019 16.11 can report C5105 from the Windows 10 SDK's own winbase.h.
-- Keep project warnings strict while excluding that toolchain-header defect.
-- Generated sources intentionally stay within portable C99.  Do not require
-- MSVC's much newer /std:c11 switch: Lua itself still builds with toolchains
-- used for legacy Windows targets, including the XP-capable MinGW/MSVC era.
local MSVC_COMPILE_FLAGS = { "/nologo", "/W4", "/WX", "/wd5105", "/MT" }
local PORTABLE_C_FLAGS = {
    "-std=c99", "-Wall", "-Wextra", "-Werror=implicit-function-declaration",
}

-- Only the official API used by our generated sources belongs here. Keep
-- lua_State opaque and avoid lua_Number/lua_Integer: their configured widths
-- cannot be inferred from the runtime version. Signatures and macros follow
-- lua.org/source/{5.1,5.2,5.3,5.4,5.5}/{lua.h,lauxlib.h,lualib.h}.html.
local LUA_MIN_HEADER = [=[
#ifndef LUAI_LUA_MIN_H
#define LUAI_LUA_MIN_H

#include <stddef.h>
#define LUAI_LUA_ABI @LUA_ABI@

typedef struct lua_State lua_State;
typedef int (*lua_CFunction)(lua_State *L);

void lua_close(lua_State *L);
int lua_gettop(lua_State *L);
void lua_settop(lua_State *L, int idx);
int lua_type(lua_State *L, int idx);
const char *lua_tolstring(lua_State *L, int idx, size_t *len);
const char *lua_pushfstring(lua_State *L, const char *fmt, ...);
void lua_pushcclosure(lua_State *L, lua_CFunction fn, int n);
void lua_createtable(lua_State *L, int narr, int nrec);
void lua_rawset(lua_State *L, int idx);
void lua_setfield(lua_State *L, int idx, const char *k);
int luaL_callmeta(lua_State *L, int obj, const char *e);
int luaL_loadstring(lua_State *L, const char *s);
lua_State *luaL_newstate(void);
#if LUAI_LUA_ABI == 505
void luaL_openselectedlibs(lua_State *L, int load, int preload);
#define luaL_openlibs(L) luaL_openselectedlibs(L, ~0, 0)
#else
void luaL_openlibs(lua_State *L);
#endif

#if LUAI_LUA_ABI == 501
void lua_pushlstring(lua_State *L, const char *s, size_t len);
void lua_pushstring(lua_State *L, const char *s);
void lua_getfield(lua_State *L, int idx, const char *k);
void lua_call(lua_State *L, int nargs, int nresults);
int lua_pcall(lua_State *L, int nargs, int nresults, int errfunc);
int luaL_loadbuffer(lua_State *L, const char *buff, size_t sz, const char *name);
#define lua_getglobal(L,s) lua_getfield(L, -10002, (s))
#define lua_setglobal(L,s) lua_setfield(L, -10002, (s))
#define lua_pushliteral(L,s) lua_pushlstring(L, "" s, sizeof(s) - 1)
#else
const char *lua_pushlstring(lua_State *L, const char *s, size_t len);
const char *lua_pushstring(lua_State *L, const char *s);
void lua_setglobal(lua_State *L, const char *name);
int luaL_loadbufferx(lua_State *L, const char *buff, size_t sz,
                     const char *name, const char *mode);
void luaL_traceback(lua_State *L, lua_State *L1, const char *msg, int level);
#if LUAI_LUA_ABI == 502
void lua_getglobal(lua_State *L, const char *name);
void lua_getfield(lua_State *L, int idx, const char *k);
void lua_callk(lua_State *L, int nargs, int nresults, int ctx, lua_CFunction k);
int lua_pcallk(lua_State *L, int nargs, int nresults, int errfunc,
               int ctx, lua_CFunction k);
#else
typedef ptrdiff_t lua_KContext;
typedef int (*lua_KFunction)(lua_State *L, int status, lua_KContext ctx);
int lua_getglobal(lua_State *L, const char *name);
int lua_getfield(lua_State *L, int idx, const char *k);
void lua_callk(lua_State *L, int nargs, int nresults,
               lua_KContext ctx, lua_KFunction k);
int lua_pcallk(lua_State *L, int nargs, int nresults, int errfunc,
               lua_KContext ctx, lua_KFunction k);
#endif
#define lua_call(L,n,r) lua_callk(L, (n), (r), 0, NULL)
#define lua_pcall(L,n,r,f) lua_pcallk(L, (n), (r), (f), 0, NULL)
#define luaL_loadbuffer(L,s,sz,n) luaL_loadbufferx(L, (s), (sz), (n), NULL)
#define lua_pushliteral(L,s) lua_pushstring(L, "" s)
#endif

#define LUA_MULTRET (-1)
#define LUA_OK 0
#define LUA_ERRSYNTAX 3
#define LUA_TSTRING 4
#define LUA_TTABLE 5
#define LUA_TFUNCTION 6
#define lua_pop(L,n) lua_settop(L, -(n)-1)
#define lua_tostring(L,i) lua_tolstring(L, (i), NULL)
#define lua_istable(L,n) (lua_type(L, (n)) == LUA_TTABLE)
#define lua_isfunction(L,n) (lua_type(L, (n)) == LUA_TFUNCTION)
#define lua_pushcfunction(L,f) lua_pushcclosure(L, (f), 0)
#define luaL_dostring(L,s) (luaL_loadstring(L, (s)) || lua_pcall(L, 0, LUA_MULTRET, 0))

#endif
]=]
local configured_timeout = tonumber(os.getenv("LUAI_CMD_TIMEOUT"))
local function compileTimeout()
    if type(configured_timeout) == "number" and configured_timeout > 0 then
        return configured_timeout
    end
    return COMPILE_TIMEOUT_SECONDS
end
local function probeTimeout()
    if type(configured_timeout) == "number" and configured_timeout > 0 then
        return configured_timeout
    end
    return PROBE_TIMEOUT_SECONDS
end

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
    if current.official == false then
        return nil, makeError(
            "UnsupportedLuaVersionError",
            "LuaJIT and other non-official Lua runtimes are not supported",
            { lua_version = current.version }
        )
    end
    if major ~= 5 or not minor or minor < 1 or minor > 5 then
        return nil, makeError(
            "UnsupportedLuaVersionError",
            "A supported official Lua 5.1 through 5.5 ABI is required",
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
    if name == "cl" or name == "cl.exe"
        or name == "clang-cl" or name == "clang-cl.exe" then
        return "msvc"
    end
    if name:find("clang", 1, true) then return "clang" end
    if name:find("gcc", 1, true) or name == "cc" then return "gcc" end
    return "cc"
end

local WINDOWS_MACHINES = {
    x86 = "X86",
    x86_64 = "X64",
    arm = "ARM",
    arm64 = "ARM64",
}

local function windowsMachine(arch)
    return WINDOWS_MACHINES[platform.normalizeArch(arch)]
end

local function windowsVersionDefines(arch, family)
    local normalized = platform.normalizeArch(arch)
    -- Desktop x86/x64 artifacts use the XP API surface. Windows on ARM did
    -- not exist on XP, so its first generally usable desktop baseline is 6.2.
    local version = (normalized == "arm" or normalized == "arm64")
        and "0x0602" or "0x0501"
    if family == "msvc" then
        return { "/D_WIN32_WINNT=" .. version, "/DWINVER=" .. version }
    end
    return { "-D_WIN32_WINNT=" .. version, "-DWINVER=" .. version }
end

local WINDOWS_SUBSYSTEM_VERSIONS = {
    x86 = { major = "5", minor = "1", msvc = "5.01" },
    x86_64 = { major = "5", minor = "2", msvc = "5.02" },
    arm = { major = "6", minor = "2", msvc = "6.02" },
    arm64 = { major = "6", minor = "2", msvc = "6.02" },
}

local function windowsSubsystemFlags(arch, family)
    local version = WINDOWS_SUBSYSTEM_VERSIONS[platform.normalizeArch(arch)]
    if not version then return nil end
    if family == "msvc" then
        return { "/SUBSYSTEM:CONSOLE," .. version.msvc }
    end
    return {
        "-Wl,--major-subsystem-version," .. version.major
            .. ",--minor-subsystem-version," .. version.minor,
    }
end

--@description: Classify a compiler command into its flag family
--@param command: string - Compiler command name or path
--@return: string - "msvc", "clang", "gcc", or "cc"
M.compilerFamily = compilerFamily

local function commandAvailable(command, family, environment)
    local argument = family == "msvc" and "/?" or "--version"
    local ok = process.outputCommand(command, { argument }, environment)
    return ok == true
end

local function regularFile(candidate)
    return type(candidate) == "string" and fs.pathType(candidate) == "file"
end

local function whereProgram(name, environment)
    local host = require("luainstaller.windows_host")
    local ok, output
    if environment and environment.PATH then
        ok, output = host.call("which", name, environment.PATH)
    else
        ok, output = host.call("which", name)
    end
    return ok and normalizePath(output) or nil
end

local function linkerSupportsBrepro(linker, environment)
    if not linker then return false end
    local _, output = process.outputCommand(linker, { "/?" }, environment)
    if tostring(output):lower():find("/brepro", 1, true) then return true end

    -- /Brepro is intentionally absent from some modern link.exe help text.
    -- Probe the option itself: without input files a recognizing linker emits
    -- another stable LNK error, whereas legacy linkers report LNK4044/LNK1117.
    local _, probe_output = process.outputCommand(
        linker,
        { "/nologo", "/Brepro" },
        environment
    )
    local probe = tostring(probe_output or "")
    local lowered = probe:lower()
    if not probe:match("LNK%d%d%d%d")
        or probe:find("LNK4044", 1, true)
        or probe:find("LNK1117", 1, true)
        or (lowered:find("/brepro", 1, true)
            and (lowered:find("unrecognized", 1, true)
                or lowered:find("unknown", 1, true)
                or lowered:find("not supported", 1, true))) then
        return false
    end
    return true
end

local function compilerFromCommand(command, family, environment)
    local compiler = {
        cc = command,
        compiler_family = family,
        environment = environment or {},
    }
    -- A Developer Command Prompt exposes cl.exe before discovery reaches
    -- vswhere. Preserve its explicitly prepared environment, but retain the
    -- companion tools needed for import-library generation and PE auditing.
    if IS_WINDOWS and family == "msvc" then
        compiler.librarian = whereProgram("lib.exe", compiler.environment)
        compiler.dumpbin = whereProgram("dumpbin.exe", compiler.environment)
        compiler.linker = whereProgram("link.exe", compiler.environment)
        compiler.supports_brepro = linkerSupportsBrepro(
            compiler.linker,
            compiler.environment
        )
    end
    return compiler
end

local function discoverMsvc(host)
    local program_files = os.getenv("ProgramFiles(x86)") or os.getenv("ProgramFiles")
    local vswhere = program_files and normalizePath(
        program_files .. "/Microsoft Visual Studio/Installer/vswhere.exe"
    ) or nil
    if not regularFile(vswhere) then return nil, "vswhere.exe was not found" end
    local ok, output = process.outputCommand(vswhere, {
        "-latest", "-prerelease", "-products", "*",
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
    local target_arch = platform.normalizeArch(host and host.arch)
    local target_dir = ({
        x86 = "x86", x86_64 = "x64", arm = "arm", arm64 = "arm64",
    })[target_arch]
    if not target_dir then
        return nil, "Visual C++ does not recognize the native architecture " .. target_arch
    end
    local binary_dir
    for _, host_dir in ipairs({ "Host" .. target_dir, "Hostx64", "Hostx86" }) do
        local candidate = normalizePath(tools_root .. "/bin/" .. host_dir .. "/" .. target_dir)
        if regularFile(candidate .. "/cl.exe") then
            binary_dir = candidate
            break
        end
    end
    if not binary_dir then
        return nil, "Visual C++ tools for the native architecture are unavailable"
    end
    local cc = normalizePath(binary_dir .. "/cl.exe")
    local librarian = normalizePath(binary_dir .. "/lib.exe")
    local dumpbin = normalizePath(binary_dir .. "/dumpbin.exe")
    local linker = normalizePath(binary_dir .. "/link.exe")
    if not regularFile(cc) or not regularFile(librarian)
        or not regularFile(dumpbin) or not regularFile(linker) then
        return nil, "Visual C++ compiler tools for " .. target_arch .. " are incomplete"
    end
    local sdk_root = normalizePath(program_files .. "/Windows Kits/10/Include")
    local sdk_entries = fs.listDirectory(sdk_root)
    local sdk_version
    for _, entry in ipairs(sdk_entries or {}) do
        if entry.type == "directory" and entry.path:match("^%d+%.%d+%.%d+%.%d+$")
            and regularFile(sdk_root .. "/" .. entry.path .. "/um/Windows.h")
            and (not sdk_version or entry.path > sdk_version) then
            sdk_version = entry.path
        end
    end
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
            tools_root .. "/lib/" .. target_dir,
            library_root .. "/ucrt/" .. target_dir,
            library_root .. "/um/" .. target_dir,
        }, ";"):gsub("/", "\\"),
        PATH = (binary_dir .. ";" .. tostring(os.getenv("PATH") or "")):gsub("/", "\\"),
    }
    return {
        cc = cc,
        compiler_family = "msvc",
        environment = environment,
        librarian = librarian,
        dumpbin = dumpbin,
        linker = linker,
        supports_brepro = linkerSupportsBrepro(linker, environment),
        target_arch = target_arch,
        discovery_source = "visual-studio",
    }
end

local function discoverCompiler(opts, host)
    local configured = opts.cc or os.getenv("LUAI_CC") or os.getenv("CC")
    if configured and configured ~= "" then
        local family = compilerFamily(configured)
        if commandAvailable(configured, family) then
            return compilerFromCommand(configured, family, {})
        end
        return nil, makeError("ToolchainError", "The configured native C compiler is unavailable", {
            compiler = configured,
        })
    end
    if host.os == "windows" then
        for _, name in ipairs({ "cl.exe", "clang.exe", "gcc.exe" }) do
            local family = compilerFamily(name)
            if commandAvailable(name, family) then
                return compilerFromCommand(name, family, {})
            end
        end
        local msvc, discovery_err = discoverMsvc(host)
        if msvc then return msvc end
        return nil, makeError("ToolchainError", "A native Windows C compiler is required", {
            cause = discovery_err,
        })
    end
    local cc = "cc"
    if not commandAvailable(cc, compilerFamily(cc)) then
        return nil, makeError("ToolchainError", "A native C compiler is required", { compiler = cc })
    end
    return compilerFromCommand(cc, compilerFamily(cc), {})
end

local function prefixFromInterpreter(interpreter)
    if type(interpreter) ~= "string" or interpreter == "" then return nil end
    local located = interpreter
    if not regularFile(located) then
        if IS_WINDOWS then
            located = whereProgram(interpreter, {})
        else
            -- Android/Termux has a POSIX shell on PATH but normally no
            -- /bin/sh.  The command is fixed and argv remains validated.
            local ok, output = process.outputCommand("sh", {
                "-c", "command -v \"$1\"", "sh", interpreter,
            })
            located = ok and trimmed(output):match("[^\r\n]+") or nil
        end
    end
    local kind = located and fs.pathType(located)
    if kind ~= "file" and kind ~= "reparse" then return nil end
    if IS_WINDOWS then return path.dirname(normalizePath(located)), normalizePath(located) end
    return path.dirname(path.dirname(normalizePath(located))), normalizePath(located)
end

local function activeLuaPrefix(opts)
    local configured = opts.lua or os.getenv("LUAI_LUA")
    if configured and configured ~= "" then return prefixFromInterpreter(configured) end
    -- `lua -e ...` and library callers may put options at arg[-1], or have
    -- no launcher arguments at all. Look for the interpreter before options.
    for index = -1, -16, -1 do
        local candidate = arg and arg[index]
        if type(candidate) == "string" and candidate:sub(1, 1) ~= "-" then
            local prefix, interpreter = prefixFromInterpreter(candidate)
            if prefix then return prefix, interpreter end
        end
    end
    return prefixFromInterpreter("lua")
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

local function hasReparseAncestor(candidate, root)
    candidate = normalizePath(path.absolute(candidate))
    root = normalizePath(path.absolute(root))
    if not path.isWithin(candidate, root) or fs.pathType(root) == "reparse" then
        return true
    end
    if candidate == root then return false end
    local prefix = root == "/" and "/" or (root .. "/")
    local relative = candidate:sub(#prefix + 1)
    local current = root
    for segment in relative:gmatch("[^/]+") do
        current = path.join(current, segment)
        if current ~= candidate and fs.pathType(current) == "reparse" then
            return true
        end
    end
    return false
end

local function resolveContainedRegularFile(candidate, root)
    candidate = normalizePath(path.absolute(candidate))
    root = normalizePath(path.absolute(root))
    local current = candidate
    local seen = {}
    for _ = 1, 16 do
        if seen[current] or not path.isWithin(current, root)
            or hasReparseAncestor(current, root) then
            return nil, "library link escapes its declared prefix or forms a cycle"
        end
        seen[current] = true
        local kind = fs.pathType(current)
        if kind == "file" then return current end
        if kind ~= "reparse" or IS_WINDOWS then
            return nil, "library candidate is not a contained regular file"
        end
        local ok, target = process.outputCommand("readlink", { current })
        target = ok and tostring(target):gsub("[\r\n]+$", "") or nil
        if not target or target == ""
            or target:find("\0", 1, true)
            or target:find("\r", 1, true)
            or target:find("\n", 1, true) then
            return nil, "library link target is invalid"
        end
        current = path.isAbsolute(target)
            and normalizePath(target)
            or path.join(path.dirname(current), target)
        current = normalizePath(path.absolute(current))
    end
    return nil, "library link chain exceeds the safety limit"
end

local function findFirstAccepted(profile, paths, root)
    local rejection
    for _, candidate in ipairs(paths) do
        local usable = regularFile(candidate)
        if not usable and root and fs.pathType(candidate) == "reparse" then
            local resolved, resolve_err = resolveContainedRegularFile(candidate, root)
            usable = resolved ~= nil
            rejection = rejection or resolve_err
        elseif usable and root then
            usable = path.isWithin(path.absolute(candidate), path.absolute(root))
                and not hasReparseAncestor(candidate, root)
            if not usable then
                rejection = rejection
                    or "library candidate escapes its declared prefix"
            end
        end
        if usable then
            local accepted, reason = native_profile.acceptsLibrary(profile, candidate)
            if accepted then return normalizePath(candidate) end
            rejection = rejection or reason
        end
    end
    return nil, rejection
end

local function prefixCandidate(prefix, lua_version, source, config)
    if type(prefix) ~= "string" or prefix == "" then return nil end
    prefix = normalizePath(path.absolute(prefix))
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
    local names = luaNames(lua_version)
    local library_paths = {}
    local extensions
    if config.host.os == "windows" then
        extensions = config.compiler_family == "msvc"
            and { ".lib", ".dll.a", ".a" }
            or { ".dll.a", ".a", ".lib" }
    elseif config.host.os == "macos" then
        extensions = { ".a", ".dylib", ".so" }
    else
        extensions = { ".so", ".a", ".dylib" }
    end
    local library_directories = {
        prefix .. "/lib",
        prefix .. "/lib64",
        prefix .. "/lib32",
    }
    local multiarch = {
        x86 = "i386-linux-gnu",
        x86_64 = "x86_64-linux-gnu",
        arm = "arm-linux-gnueabihf",
        arm64 = "aarch64-linux-gnu",
        powerpc64le = "powerpc64le-linux-gnu",
        riscv64 = "riscv64-linux-gnu",
    }
    local triplet = multiarch[platform.normalizeArch(config.host.arch)]
    if triplet then
        library_directories[#library_directories + 1] = prefix .. "/lib/" .. triplet
    end
    library_directories[#library_directories + 1] = prefix
    for _, directory in ipairs(library_directories) do
        for _, name in ipairs(names) do
            for _, extension in ipairs(extensions) do
                library_paths[#library_paths + 1] = directory .. "/lib" .. name .. extension
                library_paths[#library_paths + 1] = directory .. "/" .. name .. extension
                if extension == ".so" then
                    -- Runtime packages commonly expose only a SONAME such
                    -- as liblua5.4.so.0, without a development linker symlink.
                    library_paths[#library_paths + 1] = directory .. "/lib"
                        .. name .. extension .. ".0"
                    library_paths[#library_paths + 1] = directory .. "/lib"
                        .. name .. extension .. ".0.0.0"
                    library_paths[#library_paths + 1] = directory .. "/lib"
                        .. name .. extension .. "." .. version
                    library_paths[#library_paths + 1] = directory .. "/"
                        .. name .. extension .. "." .. version
                    library_paths[#library_paths + 1] = directory .. "/lib"
                        .. name .. extension .. "." .. lua_version.major
                    library_paths[#library_paths + 1] = directory .. "/"
                        .. name .. extension .. "." .. lua_version.major
                end
            end
        end
    end
    local library_path, policy_err = findFirstAccepted(
        config.profile,
        library_paths,
        prefix
    )

    local runtime_path
    if config.host.os == "windows" then
        local runtime_paths = {}
        for _, directory in ipairs({ prefix .. "/bin", prefix }) do
            for _, name in ipairs(names) do
                runtime_paths[#runtime_paths + 1] = directory .. "/" .. name .. ".dll"
            end
        end
        runtime_path = findFirst(runtime_paths)
        if not runtime_path then return nil, "Windows prefix does not contain a matching Lua DLL" end
        local runtime_ok, runtime_err = native_profile.acceptsLibrary(config.profile, runtime_path)
        if not runtime_ok then return nil, runtime_err end
    elseif not library_path then
        return nil, policy_err or "Lua prefix does not contain a library for the required runtime profile"
    end
    return {
        source = source,
        prefix = prefix,
        include_dir = include_dir and normalizePath(include_dir) or nil,
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
    if not library_dir then return nil end
    if include_dir and not regularFile(normalizePath(include_dir .. "/lua.h")) then
        include_dir = nil
    end
    local prefix = path.dirname(normalizePath(library_dir))
    local candidate = prefixCandidate(prefix, lua_version, "luarocks", config)
    if candidate then return candidate end
    local names = library_name and { library_name:gsub("^lib", ""):gsub("%.[^.]+$", "") }
        or luaNames(lua_version)
    local paths = {}
    for _, name in ipairs(names) do
        for _, extension in ipairs({ ".lib", ".dll.a", ".a", ".so", ".dylib" }) do
            paths[#paths + 1] = normalizePath(library_dir .. "/lib" .. name .. extension)
            paths[#paths + 1] = normalizePath(library_dir .. "/" .. name .. extension)
        end
    end
    local library_path = findFirstAccepted(config.profile, paths, prefix)
    if not library_path then return nil end
    return {
        source = "luarocks",
        include_dir = include_dir and normalizePath(include_dir) or nil,
        library_dir = normalizePath(library_dir),
        library_path = library_path,
    }
end

local function pkgConfigCandidate(lua_version, config)
    if not commandAvailable("pkg-config", "cc") then return nil end
    for _, module_name in ipairs(luaNames(lua_version)) do
        local version_ok, module_version = process.outputCommand(
            "pkg-config", { "--modversion", module_name }
        )
        if version_ok and versionMatches(module_version, lua_version) then
            local flags_ok, flags = process.outputCommand(
                "pkg-config", { "--cflags", "--libs", module_name }
            )
            local tokens
            local token_err
            if flags_ok then
                tokens, token_err = safeFlagTokens(trimmed(flags))
            end
            if tokens then
                local include_dir
                local library_dir
                local library_names = {}
                local absolute_libraries = {}
                for _, token in ipairs(tokens) do
                    include_dir = include_dir or token:match("^-I(.+)$")
                    library_dir = library_dir or token:match("^-L(.+)$")
                    local library_name = token:match("^-l(.+)$")
                    if library_name then library_names[#library_names + 1] = library_name end
                    if token:match("^[/\\]") or token:match("^%a:[/\\]") then
                        absolute_libraries[#absolute_libraries + 1] = token
                    end
                end
                if not library_dir then
                    local libdir_ok, libdir = process.outputCommand(
                        "pkg-config", { "--variable=libdir", module_name }
                    )
                    if libdir_ok and trimmed(libdir) ~= "" then
                        library_dir = trimmed(libdir)
                    end
                end
                local library_paths = copyList(absolute_libraries)
                if library_dir then
                    for _, library_name in ipairs(library_names) do
                        for _, extension in ipairs({ ".so", ".a", ".dylib", ".lib", ".dll.a" }) do
                            library_paths[#library_paths + 1] = normalizePath(
                                library_dir .. "/lib" .. library_name .. extension
                            )
                            library_paths[#library_paths + 1] = normalizePath(
                                library_dir .. "/" .. library_name .. extension
                            )
                        end
                    end
                end
                local library_path = findFirstAccepted(
                    config.profile,
                    library_paths,
                    library_dir
                )
                if library_path then
                    if native_profile.linkMode(library_path) == "static" then
                        local static_ok, static_flags = process.outputCommand(
                            "pkg-config",
                            { "--static", "--cflags", "--libs", module_name }
                        )
                        if static_ok then
                            local static_tokens, static_err = safeFlagTokens(
                                trimmed(static_flags)
                            )
                            if static_err then return nil, static_err end
                            if static_tokens then tokens = static_tokens end
                        end
                    end
                    return {
                        source = "pkg-config",
                        pkg_config_module = module_name,
                        pkg_config_version = trimmed(module_version),
                        flags = tokens,
                        include_dir = include_dir and normalizePath(include_dir) or nil,
                        library_dir = normalizePath(path.dirname(library_path)),
                        library_path = library_path,
                    }
                end
            end
            if token_err then return nil, token_err end
        end
    end
    return nil
end

local function cStringLiteral(value)
    value = tostring(value or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\r", "\\r")
        :gsub("\n", "\\n")
    return '"' .. value .. '"'
end

local function nativeModuleProbeSource()
    return [[
#include "lua_min.h"

#if defined(_WIN32)
#define LUAI_EXPORT __declspec(dllexport)
#else
#define LUAI_EXPORT
#endif

LUAI_EXPORT int luaopen_luai_native_probe(lua_State *state) {
    lua_pushliteral(state, "native-probe-ok");
    return 1;
}
]]
end

local function probeSource(lua_version, module_pattern)
    local module_script = "package.cpath = " .. string.format("%q", module_pattern)
        .. "; assert(require('luai_native_probe') == 'native-probe-ok')"
    local source = [[
#include <stdio.h>
#include <string.h>
#include "lua_min.h"

int main(void) {
    lua_State *state = luaL_newstate();
    const char *version;
    int matches;
    int module_status;
    if (!state) return 70;
    luaL_openlibs(state);
    lua_getglobal(state, "_VERSION");
    version = lua_tostring(state, -1);
    matches = version != NULL && strcmp(version, "@LUA_VERSION@") == 0;
    if (!matches) fprintf(stderr, "expected @LUA_VERSION@, got %s\n", version ? version : "unknown");
    module_status = matches ? luaL_dostring(state, @MODULE_SCRIPT@) : 1;
    if (module_status != 0) {
        const char *message = lua_tostring(state, -1);
        if (message) fprintf(stderr, "%s\n", message);
    }
    lua_close(state);
    return matches && module_status == 0 ? 0 : 42;
}
]]
    source = source:gsub("@LUA_VERSION@", lua_version.version)
    return (source:gsub("@MODULE_SCRIPT@", function()
        return cStringLiteral(module_script)
    end))
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
    local arguments = {}
    if candidate.flags then
        arguments = copyList(candidate.flags)
    elseif candidate.library_path then
        local extension = candidate.library_path:lower():match("(%.[^.]+)$")
        if config.compiler_family == "msvc" then
            if extension == ".lib" then arguments[#arguments + 1] = candidate.library_path end
        else
            arguments[#arguments + 1] = candidate.library_path
        end
    end
    if config.host.os ~= "windows" then
        for _, library in ipairs(config.profile.system_libraries or { "-lm" }) do
            local present = false
            for _, existing in ipairs(arguments) do
                if existing == library then present = true break end
            end
            if not present then arguments[#arguments + 1] = library end
        end
    end
    if native_profile.expectedLinkMode(config.profile, candidate) == "static"
        and config.host.os ~= "windows" and config.host.os ~= "macos" then
        -- Native Lua modules loaded by a statically linked interpreter resolve
        -- the Lua C API from the main executable.
        arguments[#arguments + 1] = "-Wl,-E"
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
    local machine = windowsMachine(config.profile.target_arch)
    if not machine then
        return nil, makeError("ToolchainError", "Unsupported Windows linker architecture", {
            target_arch = config.profile.target_arch,
        })
    end
    local made, make_output = process.outputCommand(config.librarian, {
        "/nologo",
        "/def:" .. definition_path:gsub("/", "\\"),
        "/out:" .. output_path:gsub("/", "\\"),
        "/MACHINE:" .. machine,
    }, config.environment)
    if not made or not regularFile(output_path) then
        return nil, makeError("ToolchainError", "Cannot generate the Lua import library", {
            output = make_output,
        })
    end
    return output_path
end

local function appendValues(target, values)
    for _, value in ipairs(values or {}) do target[#target + 1] = value end
end

local function appendPortableCompileFlags(arguments)
    appendValues(arguments, PORTABLE_C_FLAGS)
end

local function appendWindowsCompatibilityDefines(arguments, config)
    if config.host and config.host.os == "windows" then
        appendValues(arguments, windowsVersionDefines(
            config.profile and config.profile.target_arch or config.host.arch,
            config.compiler_family
        ))
    end
end

local function appendWindowsSubsystem(arguments, config)
    if not config.host or config.host.os ~= "windows" then return true end
    local flags = windowsSubsystemFlags(
        config.profile and config.profile.target_arch or config.host.arch,
        config.compiler_family
    )
    if not flags then return false end
    appendValues(arguments, flags)
    return true
end

local function appendMsvcReproducibleLink(arguments, config)
    if config.supports_brepro then arguments[#arguments + 1] = "/Brepro" end
end

local function appendMsvcReproducibleCompile(arguments, config)
    if config.supports_brepro then arguments[#arguments + 1] = "/Brepro" end
end

function M.writeLuaHeader(config, directory)
    local lua_version, version_err = luaVersionInfo(config.lua_version)
    if not lua_version then return version_err end
    local header_path = path.join(directory, "lua_min.h")
    local kind = fs.pathType(header_path)
    if fs.pathType(directory) ~= "directory"
        or (kind ~= "file" and kind ~= "missing") then
        return makeError("FilesystemError", "Cannot safely write the minimal Lua header", {
            path = header_path,
        })
    end
    local content = LUA_MIN_HEADER:gsub("@LUA_ABI@", tostring(lua_version.num))
    local wrote, write_err = fs.writeFile(header_path, content)
    if not wrote then
        return makeError("FilesystemError", "Cannot write the minimal Lua header", {
            path = header_path,
            cause = write_err,
        })
    end
    return { ok = true, path = header_path }
end

local function compileHeaderDirectory(config, output_path, opts)
    local directory = normalizePath(
        opts.lua_header_dir or opts.work_dir or path.dirname(output_path)
    )
    local written = M.writeLuaHeader(config, directory)
    if not written.ok then
        return nil, written.error.message .. ": " .. tostring(written.error.cause or written.error.path)
    end
    return directory
end

local function verifyMacosSharedRuntime(config, output_path)
    if not config.host or config.host.os ~= "macos"
        or config.link_mode ~= "shared" then
        return true
    end
    local runtime_name = config.runtime_name
    if type(runtime_name) ~= "string" or runtime_name == ""
        or runtime_name ~= path.basename(runtime_name) then
        return false, "the shared Lua dylib has no safe runtime filename"
    end
    local inspected, output = process.outputCommand(
        "otool", { "-L", output_path }, { LC_ALL = "C" }
    )
    if not inspected then
        return false, "cannot inspect the linked shared Lua dylib: " .. tostring(output)
    end
    local expected = "@rpath/" .. runtime_name
    for line in tostring(output):gmatch("[^\r\n]+") do
        local dependency = line:match("^%s*(.-)%s+%(compatibility version")
        if dependency == expected then return true end
    end
    return false, "the linked shared Lua dylib is not relocatable as " .. expected
end

function M.compile(config, source_path, output_path, opts)
    opts = opts or {}
    local header_dir, header_err = compileHeaderDirectory(config, output_path, opts)
    if not header_dir then return false, header_err end
    local arguments = {}
    if config.compiler_family == "msvc" then
        appendValues(arguments, MSVC_COMPILE_FLAGS)
        appendWindowsCompatibilityDefines(arguments, config)
        appendMsvcReproducibleCompile(arguments, config)
        local object_dir = normalizePath(opts.work_dir or path.dirname(output_path))
        local object_name = path.basename(source_path):gsub("%.[^%.]+$", "") .. ".obj"
        arguments[#arguments + 1] = "/I" .. header_dir:gsub("/", "\\")
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
            if not import then return false, import_err.error.message end
            arguments[#arguments + 1] = import:gsub("/", "\\")
        end
        arguments[#arguments + 1] = "/link"
        arguments[#arguments + 1] = "/INCREMENTAL:NO"
        appendMsvcReproducibleLink(arguments, config)
        local machine = windowsMachine(config.profile.target_arch)
        if not machine then return false, "unsupported Windows linker architecture" end
        arguments[#arguments + 1] = "/MACHINE:" .. machine
        if not appendWindowsSubsystem(arguments, config) then
            return false, "unsupported Windows subsystem architecture"
        end
    else
        appendPortableCompileFlags(arguments)
        appendWindowsCompatibilityDefines(arguments, config)
        arguments[#arguments + 1] = "-I" .. header_dir
        arguments[#arguments + 1] = source_path
        arguments[#arguments + 1] = "-o"
        arguments[#arguments + 1] = output_path
        if opts.rpath and opts.rpath ~= "" then
            arguments[#arguments + 1] = "-Wl,-rpath," .. opts.rpath
        end
        for _, value in ipairs(config.link_args or {}) do arguments[#arguments + 1] = value end
        if not appendWindowsSubsystem(arguments, config) then
            return false, "unsupported Windows subsystem architecture"
        end
    end
    local ok, output = process.outputCommand(config.cc, arguments, config.environment, {
        timeout_seconds = compileTimeout(),
    })
    local descriptor = process.command(config.cc, arguments)
    if ok then
        local runtime_ok, runtime_output = verifyMacosSharedRuntime(config, output_path)
        if not runtime_ok then return false, runtime_output, descriptor end
    end
    return ok, output, descriptor
end

function M.nativeModuleExtension(config)
    return config.host.os == "windows" and "dll" or "so"
end

function M.compileNativeModule(config, source_path, output_path, opts)
    opts = opts or {}
    local header_dir, header_err = compileHeaderDirectory(config, output_path, opts)
    if not header_dir then return false, header_err end
    local arguments = {}
    if config.compiler_family == "msvc" then
        appendValues(arguments, MSVC_COMPILE_FLAGS)
        appendWindowsCompatibilityDefines(arguments, config)
        appendMsvcReproducibleCompile(arguments, config)
        arguments[#arguments + 1] = "/LD"
        local object_dir = normalizePath(opts.work_dir or path.dirname(output_path))
        local object_name = path.basename(source_path):gsub("%.[^%.]+$", "") .. ".obj"
        arguments[#arguments + 1] = "/I" .. header_dir:gsub("/", "\\")
        if config.include_dir then
            arguments[#arguments + 1] = "/I" .. config.include_dir:gsub("/", "\\")
        end
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
            local import, import_err = generateMsvcImportLibrary(config, object_dir)
            if not import then
                return false, import_err.error.message
            end
            arguments[#arguments + 1] = import:gsub("/", "\\")
        end
        arguments[#arguments + 1] = "/link"
        arguments[#arguments + 1] = "/DLL"
        arguments[#arguments + 1] = "/INCREMENTAL:NO"
        appendMsvcReproducibleLink(arguments, config)
        local machine = windowsMachine(config.profile.target_arch)
        if not machine then return false, "unsupported Windows linker architecture" end
        arguments[#arguments + 1] = "/MACHINE:" .. machine
    else
        appendPortableCompileFlags(arguments)
        appendWindowsCompatibilityDefines(arguments, config)
        arguments[#arguments + 1] = "-I" .. header_dir
        if config.host.os == "macos" then
            arguments[#arguments + 1] = "-bundle"
            arguments[#arguments + 1] = "-undefined"
            arguments[#arguments + 1] = "dynamic_lookup"
        else
            arguments[#arguments + 1] = "-shared"
            if config.host.os ~= "windows" then
                arguments[#arguments + 1] = "-fPIC"
            end
        end
        if config.include_dir then
            arguments[#arguments + 1] = "-I" .. config.include_dir
        end
        arguments[#arguments + 1] = source_path
        arguments[#arguments + 1] = "-o"
        arguments[#arguments + 1] = output_path
        if config.host.os == "windows" then
            for _, value in ipairs(config.link_args or {}) do
                arguments[#arguments + 1] = value
            end
        end
    end
    local ok, output = process.outputCommand(config.cc, arguments, config.environment, {
        timeout_seconds = compileTimeout(),
    })
    return ok, output, process.command(config.cc, arguments)
end

function M.resolveCompiler(opts)
    opts = opts or {}
    local host = platform.detectHost()
    local compiler, compiler_err = discoverCompiler(opts, host)
    if not compiler then return nil, compiler_err end
    compiler.host = host
    compiler.profile = assert(platform.profile({
        host = host,
        target_os = host.os,
        target_arch = host.arch,
    }))
    return compiler
end

function M.compileStandalone(config, source_path, output_path, opts)
    opts = opts or {}
    local arguments = {}
    if config.compiler_family == "msvc" then
        appendValues(arguments, MSVC_COMPILE_FLAGS)
        appendWindowsCompatibilityDefines(arguments, config)
        appendMsvcReproducibleCompile(arguments, config)
        if config.host and config.host.os == "windows" then
            arguments[#arguments + 1] = "/D_CRT_SECURE_NO_WARNINGS"
        end
        local object_dir = normalizePath(opts.work_dir or path.dirname(output_path))
        local object_name = path.basename(source_path):gsub("%.[^%.]+$", "") .. ".obj"
        arguments[#arguments + 1] = source_path:gsub("/", "\\")
        arguments[#arguments + 1] = "/Fo" .. normalizePath(
            object_dir .. "/" .. object_name
        ):gsub("/", "\\")
        arguments[#arguments + 1] = "/Fe:" .. output_path:gsub("/", "\\")
        arguments[#arguments + 1] = "/link"
        arguments[#arguments + 1] = "/INCREMENTAL:NO"
        appendMsvcReproducibleLink(arguments, config)
        local machine = windowsMachine(config.profile.target_arch)
        if not machine then return false, "unsupported Windows linker architecture" end
        arguments[#arguments + 1] = "/MACHINE:" .. machine
        if not appendWindowsSubsystem(arguments, config) then
            return false, "unsupported Windows subsystem architecture"
        end
        if config.host and config.host.os == "windows" then
            arguments[#arguments + 1] = "Advapi32.lib"
        end
    else
        appendPortableCompileFlags(arguments)
        appendWindowsCompatibilityDefines(arguments, config)
        arguments[#arguments + 1] = source_path
        arguments[#arguments + 1] = "-o"
        arguments[#arguments + 1] = output_path
        if config.host and config.host.os == "windows" then
            arguments[#arguments + 1] = "-static-libgcc"
            arguments[#arguments + 1] = "-Wl,--no-insert-timestamp"
            arguments[#arguments + 1] = "-ladvapi32"
        end
        if not appendWindowsSubsystem(arguments, config) then
            return false, "unsupported Windows subsystem architecture"
        end
    end
    local ok, output = process.outputCommand(config.cc, arguments, config.environment, {
        timeout_seconds = compileTimeout(),
    })
    return ok, output, process.command(config.cc, arguments)
end

local function findLinkedRuntime(config, executable, environment)
    if config.host.os == "windows" then
        return config.runtime_path, nil, config.runtime_path
    end
    local tool = config.host.os == "macos" and "otool" or "ldd"
    local arguments = config.host.os == "macos" and { "-L", executable } or { executable }
    local ok, output = process.outputCommand(tool, arguments, environment)
    if not ok then return nil, output end
    for line in tostring(output):gmatch("[^\r\n]+") do
        local candidate
        if config.host.os == "macos" then
            candidate = line:match("^%s*(/[^%s]*[Ll]ua[^%s]*%.dylib)")
        else
            candidate = line:match("=>%s+([^%s]+)") or line:match("^%s*(/[^%s]+)")
            if candidate and candidate ~= "not"
                and not path.basename(candidate):lower():find("lua", 1, true) then
                candidate = nil
            end
        end
        if candidate and regularFile(candidate) then
            candidate = normalizePath(candidate)
            return candidate, nil, candidate
        end
        if candidate and config.library_dir
            and fs.pathType(candidate) == "reparse" then
            local resolved = resolveContainedRegularFile(
                candidate,
                config.library_dir
            )
            if resolved then
                return normalizePath(resolved), nil, normalizePath(candidate)
            end
        end
    end
    return nil, output
end

local function sharedRuntimeInstallName(config, candidate)
    local library_path = candidate and candidate.library_path
    if type(library_path) ~= "string" or library_path == "" then return nil end
    if config.host.os == "macos" then
        local ok, output = process.outputCommand(
            "otool", { "-D", library_path }, { LC_ALL = "C" }
        )
        if ok then
            local first = true
            for line in tostring(output):gmatch("[^\r\n]+") do
                if first then
                    first = false
                else
                    local install_name = trimmed(line)
                    local name = path.basename(install_name)
                    if name ~= "" and not name:find("[\\/]", 1) then return name end
                end
            end
        end
        return path.basename(library_path)
    end
    for _, inspection in ipairs({
        { "readelf", { "-d", library_path } },
        { "llvm-readelf", { "-d", library_path } },
        { "objdump", { "-p", library_path } },
        { "llvm-objdump", { "-p", library_path } },
    }) do
        local ok, output = process.outputCommand(
            inspection[1], inspection[2], { LC_ALL = "C" }
        )
        if ok then
            for line in tostring(output):gmatch("[^\r\n]+") do
                local name = line:match("%(SONAME%)%s+Library soname:%s+%[([^%]]+)%]")
                    or line:match("^%s*SONAME%s+([^%s]+)")
                if name and name ~= "" and name == path.basename(name)
                    and not name:find("[%c/\\]") then
                    return name
                end
            end
        end
    end
    -- A shared object without DT_SONAME is loaded under the basename supplied
    -- to the linker. This is also the least-surprising fallback when a very
    -- small native environment has no object-file inspection utility.
    return path.basename(library_path)
end

local LINUX_SYSTEM_LIBRARIES = {
    "^libc%.so", "^libm%.so", "^libdl%.so", "^libpthread%.so", "^librt%.so",
    "^libresolv%.so", "^libutil%.so", "^libanl%.so",
    "^ld%-linux", "^ld%-musl", "^linux%-vdso",
}

local function systemDependency(os_name, name, resolved)
    if os_name == "macos" then
        local function systemPath(value)
            return type(value) == "string" and
                (value:sub(1, 9) == "/usr/lib/" or value:sub(1, 8) == "/System/")
        end
        return systemPath(name) or systemPath(resolved)
    end
    for _, pattern in ipairs(LINUX_SYSTEM_LIBRARIES) do
        if path.basename(name):match(pattern) then return true end
    end
    -- libstdc++ and libgcc_s are deliberately reported. Bundling them can
    -- help some targets but can also conflict with the target's glibc. This
    -- diagnostic makes no automatic exclusion or shipping decision for them.
    return false
end

local function dependencyCommand(command, arguments)
    return process.outputCommand(command, arguments, { LC_ALL = "C" }, {
        timeout_seconds = math.min(probeTimeout(), 10),
    })
end

local function linuxDependencies(binary)
    local ok, output = dependencyCommand("ldd", { binary })
    local dependencies = {}
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        local name, target = line:match("^%s*(.-)%s+=>%s+(.-)%s*$")
        if name and target then
            local resolved = target:match("^(.-)%s+%([^)]+%)%s*$") or target
            local missing = resolved:match("^not found%s*$") ~= nil
            if missing or path.isAbsolute(resolved) then
                dependencies[#dependencies + 1] = {
                    name = name, path = not missing and normalizePath(resolved) or nil,
                    missing = missing,
                }
            end
        else
            local resolved = line:match("^%s*(/.-)%s+%([^)]+%)%s*$")
            if resolved then
                dependencies[#dependencies + 1] = {
                    name = path.basename(resolved), path = normalizePath(resolved), missing = false,
                }
            end
        end
    end
    -- Some ldd implementations return nonzero while still listing unresolved
    -- libraries. Preserve those useful records and mark incomplete scans.
    local complete = ok or tostring(output):find("statically linked", 1, true) ~= nil
    return dependencies, complete, not complete and tostring(output) or nil
end

local function macosExpandPath(value, binary, executable)
    if value == "@loader_path" then return path.dirname(binary) end
    if value:sub(1, 13) == "@loader_path/" then
        return path.join(path.dirname(binary), value:sub(14))
    end
    if executable and value == "@executable_path" then return path.dirname(executable) end
    if executable and value:sub(1, 17) == "@executable_path/" then
        return path.join(path.dirname(executable), value:sub(18))
    end
    return path.isAbsolute(value) and normalizePath(value) or nil
end

local function macosDependencies(binary, inherited_rpaths, executable)
    local ok, output = dependencyCommand("otool", { "-L", binary })
    if not ok then return {}, false, tostring(output), inherited_rpaths end
    local rpaths = {}
    local load_ok, load_output = dependencyCommand("otool", { "-l", binary })
    local is_rpath = false
    if load_ok then
        for line in tostring(load_output):gmatch("[^\r\n]+") do
            local command = line:match("^%s*cmd%s+(%S+)")
            if command then is_rpath = command == "LC_RPATH" end
            local value = is_rpath and line:match("^%s*path%s+(.-)%s+%(offset")
            local expanded = value and macosExpandPath(value, binary, executable)
            if expanded then rpaths[#rpaths + 1] = expanded end
        end
    end
    for _, inherited in ipairs(inherited_rpaths or {}) do rpaths[#rpaths + 1] = inherited end
    local id_ok, id_output = dependencyCommand("otool", { "-D", binary })
    local install_name = id_ok and tostring(id_output):match("[^\r\n]+[\r\n]+%s*([^\r\n]+)")
    local dependencies = {}
    local unresolved_rpath = false
    for line in tostring(output):gmatch("[^\r\n]+") do
        local name = line:match("^%s*(.-)%s+%(compatibility version")
        if name and name ~= install_name then
            local resolved = macosExpandPath(name, binary, executable)
            if name:sub(1, 7) == "@rpath/" then
                for _, root in ipairs(rpaths) do
                    local candidate = path.join(root, name:sub(8))
                    local kind = fs.pathType(candidate)
                    if kind == "file" or kind == "reparse" then resolved = candidate break end
                end
                if not load_ok then unresolved_rpath = true end
            end
            local kind = resolved and fs.pathType(resolved)
            dependencies[#dependencies + 1] = {
                name = name, path = resolved,
                missing = kind ~= "file" and kind ~= "reparse",
            }
        end
    end
    return dependencies, not unresolved_rpath,
        unresolved_rpath and "otool could not inspect LC_RPATH" or nil, rpaths
end

local function inspectNativeDependencies(config, module_path, opts)
    local os_name = config.host.os
    if os_name ~= "linux" and os_name ~= "macos" then
        return {
            ok = true, checked = false, dependencies = {},
            reason = os_name == "windows" and "Windows DLL dependencies were not checked"
                or "Native system dependencies were not checked on " .. tostring(os_name),
        }
    end
    local dependencies, seen_names, seen_paths = {}, {}, {}
    local queue = { { path = normalizePath(module_path), rpaths = {} } }
    local queued_paths = { [normalizePath(module_path)] = true }
    local unchecked = {}
    local bundled = opts.bundled_libraries or {}
    local index = 1
    while index <= #queue do
        local current = queue[index]
        index = index + 1
        if not seen_paths[current.path] then
            seen_paths[current.path] = true
            local records, complete, reason, rpaths
            if os_name == "macos" then
                records, complete, reason, rpaths = macosDependencies(
                    current.path, current.rpaths, opts.executable_path or config.lua_executable
                )
            else
                records, complete, reason = linuxDependencies(current.path)
            end
            if not complete then
                unchecked[#unchecked + 1] = current.path .. ": " .. tostring(reason)
            end
            for _, dependency in ipairs(records) do
                local name = dependency.name
                -- ldd's explicit failure takes precedence over the Linux
                -- baseline. macOS system libraries can live only in dyld's
                -- shared cache, so their absence from disk is not evidence
                -- that they are missing.
                if (os_name == "linux" and dependency.missing
                        or not systemDependency(os_name, name, dependency.path))
                    and not bundled[name] and not bundled[path.basename(name)]
                    and dependency.path ~= normalizePath(module_path) then
                    if not seen_names[name] then
                        seen_names[name] = true
                        dependency.parent = current.path
                        dependencies[#dependencies + 1] = dependency
                    end
                    if dependency.path and not dependency.missing
                        and not queued_paths[dependency.path] then
                        queued_paths[dependency.path] = true
                        queue[#queue + 1] = { path = dependency.path, rpaths = rpaths or {} }
                    end
                end
            end
        end
    end
    table.sort(dependencies, function(left, right) return left.name < right.name end)
    return {
        ok = true, checked = #unchecked == 0, dependencies = dependencies,
        reason = #unchecked > 0 and table.concat(unchecked, "\n") or nil,
    }
end

function M.inspectNativeDependencies(config, module_path, opts)
    local called, inspected = pcall(inspectNativeDependencies, config, module_path, opts or {})
    if called then return inspected end
    return {
        ok = true, checked = false, dependencies = {},
        reason = "Native dependency inspection failed: " .. tostring(inspected),
    }
end

local function verifyCandidate(config, candidate)
    local directory, directory_err = makeProbeDirectory()
    if not directory then return nil, directory_err end
    local source_path = normalizePath(directory .. "/probe.c")
    local executable_path = normalizePath(directory .. "/probe" .. config.executable_suffix)
    local module_source_path = normalizePath(directory .. "/native-probe.c")
    local module_extension = M.nativeModuleExtension(config)
    local module_path = normalizePath(
        directory .. "/luai_native_probe." .. module_extension
    )
    local module_pattern = normalizePath(directory .. "/?." .. module_extension)
    local wrote, write_err = fs.writeFile(
        module_source_path,
        nativeModuleProbeSource()
    )
    if not wrote then
        cleanupProbeDirectory(directory)
        return nil, makeError("FilesystemError", "Cannot write the native-module probe", {
            path = module_source_path,
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
    local module_compiled, module_output, module_command = M.compileNativeModule(
        config,
        module_source_path,
        module_path,
        { work_dir = directory }
    )
    if not module_compiled then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "Lua C-module capability probe did not compile", {
            command = module_command,
            output = module_output,
            source = candidate.source,
        })
    end
    wrote, write_err = fs.writeFile(
        source_path,
        probeSource(config.lua_version, module_pattern)
    )
    if not wrote then
        cleanupProbeDirectory(directory)
        return nil, makeError("FilesystemError", "Cannot write the toolchain probe", {
            path = source_path,
            cause = write_err,
        })
    end
    local compiled, compile_output, command = M.compile(config, source_path, executable_path, {
        work_dir = directory,
    })
    if not compiled then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "Lua runtime toolchain probe did not compile", {
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
    local environment = { LC_ALL = "C" }
    local library_path_var = config.profile.runtime_library_path_var
    if library_path_var and config.library_dir then
        environment[library_path_var] = config.library_dir
    end
    local ran, run_output = process.outputCommand(executable_path, {}, environment, {
        timeout_seconds = probeTimeout(),
    })
    if not ran then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "Linked Lua runtime or C-module probe failed", {
            output = run_output,
            expected = config.lua_version.version,
        })
    end
    local runtime_path, runtime_output, runtime_identity = findLinkedRuntime(
        config,
        executable_path,
        environment
    )
    local expected_link_mode = native_profile.expectedLinkMode(config.profile, candidate)
    -- ldd is optional on small Android/Termux installations and its output is
    -- not standardized across the BSDs.  The exact accepted library candidate
    -- remains a valid identity fallback after the compile-and-run ABI probe.
    if expected_link_mode == "shared" and not runtime_path
        and candidate.library_path
        and native_profile.linkMode(candidate.library_path) == "shared" then
        local fallback_path = candidate.library_path
        if fs.pathType(fallback_path) == "reparse" then
            fallback_path = resolveContainedRegularFile(
                fallback_path,
                candidate.library_dir or path.dirname(fallback_path)
            )
        end
        runtime_path = fallback_path
        local install_name = sharedRuntimeInstallName(config, candidate)
        runtime_identity = install_name and normalizePath(
            path.dirname(candidate.library_path) .. "/" .. install_name
        ) or candidate.library_path
    end
    if runtime_path then
        local runtime_ok, runtime_err = native_profile.acceptsLibrary(
            config.profile,
            runtime_identity or runtime_path
        )
        if not runtime_ok then
            cleanupProbeDirectory(directory)
            return nil, makeError("ToolchainError", runtime_err, {
                runtime_path = runtime_path,
            })
        end
    end
    if expected_link_mode == "shared" and not runtime_path then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "The native profile requires a linked shared liblua runtime", {
            output = runtime_output,
        })
    end
    if expected_link_mode == "static" and runtime_path then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "The native profile requires static liblua.a", {
            runtime_path = runtime_path,
        })
    end
    if runtime_path then
        config.runtime_path = runtime_path
        config.runtime_name = path.basename(runtime_identity or runtime_path)
    end
    if not expected_link_mode then
        cleanupProbeDirectory(directory)
        return nil, makeError("ToolchainError", "Cannot determine the Lua runtime link mode", {
            library_path = candidate.library_path,
        })
    end
    config.link_mode = expected_link_mode
    config.static_library_path = expected_link_mode == "static"
        and candidate.library_path or nil
    config.native_module_verified = true
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
    local active_prefix, active_interpreter = activeLuaPrefix(opts)
    config.lua_executable = active_interpreter
    local requested_prefix = opts.lua_prefix or os.getenv("LUAI_LUA_PREFIX")
    if type(requested_prefix) == "string" and requested_prefix ~= "" then
        local explicit, prefix_err = prefixCandidate(
            requested_prefix,
            lua_version,
            "explicit-prefix",
            config
        )
        if not explicit then
            return nil, makeError(
                "ToolchainError",
                "Lua prefix does not contain a library for the selected Lua ABI",
                {
                    lua_prefix = normalizePath(requested_prefix),
                    lua_abi = lua_version.abi,
                    cause = prefix_err,
                }
            )
        end
        candidates[#candidates + 1] = explicit
    else
        local active = prefixCandidate(
            active_prefix,
            lua_version,
            "active-lua",
            config
        )
        if active then candidates[#candidates + 1] = active end
        local rock = luarocksCandidate(lua_version, config)
        if rock then candidates[#candidates + 1] = rock end
        if host.os ~= "windows" then
            local pkg, pkg_err = pkgConfigCandidate(lua_version, config)
            if pkg_err then return nil, pkg_err end
            if pkg then candidates[#candidates + 1] = pkg end
        end
    end
    if #candidates == 0 then
        return nil, makeError("ToolchainError", "No Lua library matches the selected ABI", {
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
    config.linker = compiler.linker
    config.supports_brepro = compiler.supports_brepro

    local failures = {}
    for _, candidate in ipairs(candidates) do
        local verified, verify_err = verifyCandidate(config, candidate)
        if verified then return verified end
        failures[#failures + 1] = verify_err.error
    end
    return nil, makeError(
        "ToolchainError",
        "Cannot resolve a verified native toolchain for the linked Lua runtime",
        {
            lua_abi = lua_version.abi,
            compiler = config.cc,
            failures = failures,
        }
    )
end

return M
