#include <lua.h>
#include <lauxlib.h>

#if defined(_WIN32)
#define LUAI_EXPORT __declspec(dllexport)
#else
#define LUAI_EXPORT
#endif

static void luai_probe_version_api(lua_State *state) {
#if LUA_VERSION_NUM == 501
    lua_pushliteral(state, "api");
    if (lua_objlen(state, -1) != 3) luaL_error(state, "Lua 5.1 API probe failed");
    lua_pop(state, 1);
#elif LUA_VERSION_NUM == 502
    luaL_checkversion(state);
    lua_pushliteral(state, "api");
    if (lua_absindex(state, -1) != lua_gettop(state) || lua_rawlen(state, -1) != 3) {
        luaL_error(state, "Lua 5.2 API probe failed");
    }
    lua_pop(state, 1);
#elif LUA_VERSION_NUM == 503
    luaL_checkversion(state);
    lua_pushinteger(state, 503);
    if (!lua_isinteger(state, -1)) luaL_error(state, "Lua 5.3 API probe failed");
    lua_pop(state, 1);
#elif LUA_VERSION_NUM == 504
    unsigned char *memory;
    luaL_checkversion(state);
    memory = (unsigned char *)lua_newuserdatauv(state, 1, 1);
    memory[0] = 54;
    lua_pop(state, 1);
#elif LUA_VERSION_NUM == 505
    char buffer[LUA_N2SBUFFSZ];
    luaL_checkversion(state);
    lua_pushnumber(state, 55.0);
    if (lua_numbertocstring(state, -1, buffer) == 0 || buffer[0] == '\0') {
        luaL_error(state, "Lua 5.5 API probe failed");
    }
    lua_pop(state, 1);
#else
#error "native probe requires an official Lua 5.1 through 5.5 API"
#endif
}

LUAI_EXPORT int luaopen_luai_native_probe(lua_State *state) {
    luai_probe_version_api(state);
    lua_pushliteral(state, "native-probe-ok");
    return 1;
}
