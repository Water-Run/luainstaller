#include <lua.h>
#include <lauxlib.h>

#if defined(_WIN32)
#define LUAI_EXPORT __declspec(dllexport)
#else
#define LUAI_EXPORT
#endif

LUAI_EXPORT int luaopen_luai_native_probe(lua_State *state) {
    lua_pushliteral(state, "native-probe-ok");
    return 1;
}
