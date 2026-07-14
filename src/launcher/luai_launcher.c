/*
 * Shared-Lua launcher template for luainstaller.
 */

#ifndef _WIN32
#define _POSIX_C_SOURCE 200809L
#define _XOPEN_SOURCE 700
#endif

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

static int luai_traceback(lua_State *L)
{
    const char *message = lua_tostring(L, 1);
    if (message == NULL)
    {
        if (luaL_callmeta(L, 1, "__tostring") && lua_type(L, -1) == LUA_TSTRING)
        {
            return 1;
        }
        message = "(error object is not a string)";
    }
#if LUA_VERSION_NUM == 501
    lua_getglobal(L, "debug");
    if (!lua_istable(L, -1))
    {
        lua_pop(L, 1);
        lua_pushstring(L, message);
        return 1;
    }
    lua_getfield(L, -1, "traceback");
    if (!lua_isfunction(L, -1))
    {
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

static int luai_executable_path(char *out, size_t out_size)
{
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
    if (length >= out_size)
    {
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

static void luai_push_arg(lua_State *L, int argc, char **argv)
{
    char executable[4096];
    const char *arg0 = argv[0];
    int i;
    if (luai_executable_path(executable, sizeof(executable)) == 0)
    {
        arg0 = executable;
    }
    lua_createtable(L, argc > 1 ? argc - 1 : 0, 1);
    lua_pushstring(L, arg0);
    lua_rawseti(L, -2, 0);
    for (i = 1; i < argc; ++i)
    {
        lua_pushstring(L, argv[i]);
        lua_rawseti(L, -2, i);
    }
    lua_setglobal(L, "arg");
}

static int luai_load_bootstrap(lua_State *L)
{
#if LUA_VERSION_NUM == 501
    if (luai_bootstrap_size > 0 && luai_bootstrap[0] == 0x1b) return LUA_ERRSYNTAX;
    return luaL_loadbuffer(L, (const char *)luai_bootstrap, luai_bootstrap_size, "@luainstaller-bootstrap");
#else
    return luaL_loadbufferx(L, (const char *)luai_bootstrap, luai_bootstrap_size, "@luainstaller-bootstrap", "t");
#endif
}

static int luai_runtime_matches(lua_State *L)
{
    const char *version;
    int matches;
    lua_getglobal(L, "_VERSION");
    version = lua_tostring(L, -1);
    matches = version != NULL && strcmp(version, "@LUA_VERSION@") == 0;
    lua_pop(L, 1);
    return matches;
}

int main(int argc, char **argv)
{
    lua_State *L;
    int status;
    int traceback_index;

    L = luaL_newstate();
    if (L == NULL)
    {
        fputs("luainstaller: cannot create Lua state\n", stderr);
        return 70;
    }

    luaL_openlibs(L);
    if (!luai_runtime_matches(L))
    {
        fputs("luainstaller: linked Lua runtime is not @LUA_VERSION@\n", stderr);
        lua_close(L);
        return 70;
    }
    luai_push_arg(L, argc, argv);

    lua_pushcfunction(L, luai_traceback);
    traceback_index = lua_gettop(L);

    status = luai_load_bootstrap(L);
    if (status == LUA_OK)
    {
        status = lua_pcall(L, 0, LUA_MULTRET, traceback_index);
    }

    if (status != LUA_OK)
    {
        const char *message = lua_tostring(L, -1);
        fprintf(stderr, "luainstaller: %s\n", message ? message : "unknown launcher error");
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}
