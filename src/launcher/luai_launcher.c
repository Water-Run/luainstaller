/*
 * Shared-Lua launcher template for luainstaller.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>

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
    luaL_traceback(L, L, message, 1);
    return 1;
}

static void luai_push_arg(lua_State *L, int argc, char **argv)
{
    int i;
    lua_createtable(L, argc > 1 ? argc - 1 : 0, 1);
    lua_pushstring(L, argv[0]);
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
#if LUA_VERSION_NUM >= 502
    return luaL_loadbufferx(L, (const char *)luai_bootstrap, luai_bootstrap_size, "@luainstaller-bootstrap", "t");
#else
    return luaL_loadbuffer(L, (const char *)luai_bootstrap, luai_bootstrap_size, "@luainstaller-bootstrap");
#endif
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
