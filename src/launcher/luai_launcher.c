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
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0501
#endif
#ifndef WINVER
#define WINVER _WIN32_WINNT
#endif
#include <windows.h>
#elif defined(__APPLE__)
#include <mach-o/dyld.h>
#include <unistd.h>
#elif defined(__FreeBSD__) || defined(__DragonFly__)
#include <sys/types.h>
#include <sys/sysctl.h>
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

#ifndef _WIN32
static int luai_copy_path(char *out, size_t out_size, const char *value)
{
    size_t length;
    if (value == NULL) return -1;
    length = strlen(value);
    if (length == 0 || length >= out_size) return -1;
    memcpy(out, value, length + 1);
    return 0;
}

static int luai_real_executable(char *out, size_t out_size, const char *candidate)
{
    char resolved[4096];
    if (candidate == NULL || realpath(candidate, resolved) == NULL) return -1;
    if (access(resolved, X_OK) != 0) return -1;
    return luai_copy_path(out, out_size, resolved);
}

static int luai_executable_from_argv0(char *out, size_t out_size, const char *arg0)
{
    const char *search;
    const char *cursor;
    if (arg0 == NULL || *arg0 == '\0') return -1;
    if (strchr(arg0, '/') != NULL) return luai_real_executable(out, out_size, arg0);
    search = getenv("PATH");
    if (search == NULL) return -1;
    cursor = search;
    for (;;)
    {
        const char *separator = strchr(cursor, ':');
        size_t directory_length = separator ? (size_t)(separator - cursor) : strlen(cursor);
        char candidate[4096];
        int length;
        if (directory_length == 0)
        {
            length = snprintf(candidate, sizeof(candidate), "./%s", arg0);
        }
        else if (directory_length >= sizeof(candidate) - 2)
        {
            length = -1;
        }
        else
        {
            length = snprintf(candidate, sizeof(candidate), "%.*s/%s",
                              (int)directory_length, cursor, arg0);
        }
        if (length > 0 && (size_t)length < sizeof(candidate)
            && luai_real_executable(out, out_size, candidate) == 0) return 0;
        if (!separator) break;
        cursor = separator + 1;
    }
    return -1;
}
#endif

static int luai_executable_path(char *out, size_t out_size, const char *arg0)
{
#ifdef _WIN32
    DWORD length = GetModuleFileNameA(NULL, out, (DWORD)out_size);
    if (length == 0 || (size_t)length >= out_size) return -1;
    return 0;
#elif defined(__APPLE__)
    char raw[4096];
    uint32_t size = (uint32_t)sizeof(raw);
    if (_NSGetExecutablePath(raw, &size) != 0) return -1;
    if (luai_real_executable(out, out_size, raw) == 0) return 0;
#elif defined(__FreeBSD__) || defined(__DragonFly__)
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PATHNAME, -1 };
    size_t size = out_size;
    if (sysctl(mib, 4, out, &size, NULL, 0) == 0
        && size > 1 && size <= out_size && out[0] != '\0') return 0;
#elif defined(__linux__) || defined(__ANDROID__)
    ssize_t length = readlink("/proc/self/exe", out, out_size - 1);
    if (length >= 0 && (size_t)length < out_size - 1)
    {
        out[length] = '\0';
        return 0;
    }
#else
    (void)out;
    (void)out_size;
#endif
#ifndef _WIN32
    return luai_executable_from_argv0(out, out_size, arg0);
#else
    (void)arg0;
    return -1;
#endif
}

static void luai_push_arg(lua_State *L, int argc, char **argv)
{
    char executable[4096];
    const char *arg0 = argc > 0 && argv[0] != NULL ? argv[0] : "";
    const char *executable_path = arg0;
    int i;
    if (luai_executable_path(executable, sizeof(executable), arg0) == 0)
    {
        executable_path = executable;
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
    lua_pushstring(L, executable_path);
    lua_setglobal(L, "__luai_executable_path");
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
