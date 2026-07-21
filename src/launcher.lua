--[[
Shared-Lua C launcher source generation for luainstaller.

Author:
    WaterRun
File:
    launcher.lua
Date:
    2026-06-16
Updated:
    2026-07-11
]]

local cgen = require("luainstaller.cgen")
local compat = require("luainstaller.compat")

local M = {}

local DEFAULT_TEMPLATE = [=[
/*
 * Shared-Lua launcher template for luainstaller.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#include <unistd.h>
#else
#include <unistd.h>
#endif

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

#if !defined(LUA_VERSION_NUM) || LUA_VERSION_NUM != @LUA_VERSION_NUM@
#error "luainstaller was generated for a different Lua ABI"
#endif

#ifndef LUA_OK
#define LUA_OK 0
#endif

static int luai_traceback(lua_State *L) {
    const char *message = lua_tostring(L, 1);
    if (message == NULL) {
        if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING) {
            return 1;
        }
        message = "(error object is not a string)";
    }
#if LUA_VERSION_NUM == 501
    lua_getglobal(L, "debug");
    if (!lua_istable(L, -1)) {
        lua_pop(L, 1);
        lua_pushstring(L, message);
        return 1;
    }
    lua_getfield(L, -1, "traceback");
    if (!lua_isfunction(L, -1)) {
        lua_pop(L, 2);
        lua_pushstring(L, message);
        return 1;
    }
    lua_pushstring(L, message);
    lua_pushinteger(L, 2);
    lua_call(L, 2, 1);
#else
    luaL_traceback(L, L, message, 1);
#endif
    return 1;
}

static int luai_executable_path(char *out, size_t out_size) {
#ifdef _WIN32
    DWORD length = GetModuleFileNameA(NULL, out, (DWORD)out_size);
    if (length == 0 || (size_t)length >= out_size) return -1;
    return 0;
#elif defined(__APPLE__)
    char raw[4096];
    char *resolved;
    size_t length;
    uint32_t size = (uint32_t)sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0) return -1;
    resolved = realpath(raw, NULL);
    if (!resolved) return -1;
    length = strlen(resolved);
    if (length >= out_size) {
        free(resolved);
        return -1;
    }
    memcpy(out, resolved, length + 1);
    free(resolved);
    return 0;
#else
    ssize_t length = readlink("/proc/self/exe", out, out_size - 1);
    if (length < 0 || (size_t)length >= out_size - 1) return -1;
    out[length] = '\0';
    return 0;
#endif
}

static void luai_push_arg(lua_State *L, int argc, char **argv) {
    char executable[4096];
    const char *arg0 = argc > 0 && argv[0] != NULL ? argv[0] : "";
    const char *executable_path = arg0;
    int i;
    if (luai_executable_path(executable, sizeof(executable)) == 0) {
        executable_path = executable;
    }
    lua_createtable(L, argc > 1 ? argc - 1 : 0, 1);
    lua_pushstring(L, arg0);
    lua_rawseti(L, -2, 0);
    for (i = 1; i < argc; ++i) {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");
    lua_pushstring(L, executable_path);
    lua_setglobal(L, "__luai_executable_path");
}

static int luai_load_bootstrap(lua_State *L) {
#if LUA_VERSION_NUM == 501
    if (luai_bootstrap_size > 0 && luai_bootstrap[0] == 0x1b) return LUA_ERRSYNTAX;
    return luaL_loadbuffer(L, (const char *)luai_bootstrap, luai_bootstrap_size, "@luainstaller-bootstrap");
#else
    return luaL_loadbufferx(L, (const char *)luai_bootstrap, luai_bootstrap_size, "@luainstaller-bootstrap", "t");
#endif
}

static int luai_runtime_matches(lua_State *L) {
    const char *version;
    int matches;
    lua_getglobal(L, "_VERSION");
    version = lua_tostring(L, -1);
    matches = version != NULL && strcmp(version, "@LUA_VERSION@") == 0;
    lua_pop(L, 1);
    return matches;
}

int main(int argc, char **argv) {
    lua_State *L;
    int status;
    int traceback_index;

    L = luaL_newstate();
    if (L == NULL) {
        fputs("luainstaller: cannot create Lua state\n", stderr);
        return 70;
    }

    luaL_openlibs(L);
    if (!luai_runtime_matches(L)) {
        fputs("luainstaller: linked Lua runtime is not @LUA_VERSION@\n", stderr);
        lua_close(L);
        return 70;
    }
    luai_push_arg(L, argc, argv);

    lua_pushcfunction(L, luai_traceback);
    traceback_index = lua_gettop(L);

    status = luai_load_bootstrap(L);
    if (status == LUA_OK) {
        status = lua_pcall(L, 0, LUA_MULTRET, traceback_index);
    }

    if (status != LUA_OK) {
        const char *message = lua_tostring(L, -1);
        fprintf(stderr, "luainstaller: %s\n", message ? message : "unknown launcher error");
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}
]=]

local function readFile(path)
    local handle = io.open(path, "rb")
    if not handle then
        error({
            type = "LauncherTemplateNotFoundError",
            message = "Cannot read launcher template: " .. tostring(path),
            path = path,
        })
    end
    local content = handle:read("*a")
    handle:close()
    return content or ""
end

local function luaVersionInfo(configured)
    local current = configured or compat.luaVersion()
    local major = tonumber(current.major)
    local minor = tonumber(current.minor)
    local number = tonumber(current.num) or (major and minor and (major * 100 + minor))
    if major ~= 5 or not minor or minor < 1 or not number then
        error({
            type = "UnsupportedLuaVersionError",
            message = "A supported official Lua 5.1+ ABI is required to generate a launcher",
            lua_version = current.version,
        })
    end
    return {
        version = string.format("Lua %d.%d", major, minor),
        major = major,
        minor = minor,
        num = number,
        abi = current.abi or string.format("lua%d.%d", major, minor),
    }
end

local function renderTemplate(template, lua_version)
    template = template:gsub("@LUA_VERSION_NUM@", tostring(lua_version.num))
    template = template:gsub("@LUA_VERSION@", lua_version.version)
    return template
end

function M.bytesFromString(source)
    source = tostring(source or "")
    local bytes = {}
    for i = 1, #source do
        bytes[#bytes + 1] = string.format("0x%02X", source:byte(i))
    end
    return bytes
end

local function emitBytes(name, source)
    local bytes = M.bytesFromString(source)
    local lines = {}
    lines[#lines + 1] = "static const unsigned char " .. name .. "[] = {"
    for i = 1, #bytes, 12 do
        local chunk = {}
        for j = i, math.min(i + 11, #bytes) do
            chunk[#chunk + 1] = bytes[j]
        end
        lines[#lines + 1] = "    " .. table.concat(chunk, ", ") .. ","
    end
    lines[#lines + 1] = "};"
    lines[#lines + 1] = "static const size_t " .. name .. "_size = sizeof(" .. name .. ");"
    return table.concat(lines, "\n")
end

function M.generateSource(opts)
    opts = opts or {}
    if not opts.entry then
        error({
            type = "InvalidOptionsError",
            message = "entry is required",
        })
    end

    local lua_version = luaVersionInfo(opts.lua_version)
    local generation_opts = {}
    for key, value in pairs(opts) do
        generation_opts[key] = value
    end
    generation_opts.lua_version = lua_version
    local bootstrap = cgen.generateBootstrap(generation_opts)
    local template = opts.template_path and readFile(opts.template_path) or DEFAULT_TEMPLATE
    template = renderTemplate(template, lua_version)
    return table.concat({
        "/* Generated by luainstaller. */",
        "#ifndef _WIN32",
        "#define _POSIX_C_SOURCE 200809L",
        "#define _XOPEN_SOURCE 700",
        "#endif",
        "#include <stddef.h>",
        emitBytes("luai_bootstrap", bootstrap),
        template,
        "",
    }, "\n\n")
end


M.generate = M.generateSource

return M
