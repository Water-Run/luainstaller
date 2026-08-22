#!/bin/sh
set -eu

# Install the complete pinned sample dependency graph directly against the CI
# Lua prefix. Source inputs, digests, and installation order mirror the release
# matrix (tools/test-lua-versions.sh and docs/TESTING.adoc); downloads are
# SHA-256 verified and LuaRocks dependency resolution is disabled. lsqlite3 is
# compiled directly from its pinned binding and SQLite amalgamation sources.

PREFIX=${LUAI_CI_LUA_PREFIX:-$HOME/luai-lua}
TREE=${LUAI_CI_ROCKS_TREE:-$HOME/luai-rocks}
WORK=${LUAI_CI_WORK:-/tmp/luai-ci-deps}
ROCK_MIRROR=https://raw.githubusercontent.com/rocks-moonscript-org/moonrocks-mirror/978861950d939eca8e38a4c3a477379b0e5f817e

ROCK_SOURCES='lua-cjson-2.1.0.10-1.src.rock:02dea368d07753647c75bd9e6660dd4d06ff7d09956d90d5afc4c3f5b78ed187
luafilesystem-1.9.0-1.src.rock:3de68d619f6ad95a27f4728814375447d921305194b7050dee6199057c31282f
luasocket-3.1.0-1.src.rock:f4a207f50a3f99ad65def8e29c54ac9aac668b216476f7fae3fae92413398ed2
mimetypes-1.1.0-2.src.rock:2cf77e0b6575caa6aecb43c9a06f705b1e7d92c19c5da6bb2f07a10feeee9e2f
lzlib-0.4.1.53-4.src.rock:860c893fc53d0a7830a54fa64f22a2b89260ca39c9a7dcb0890f6d3029f00ca5
pegasus-1.1.0-0.src.rock:0f91f10e354183db06c0c2dfa878b97a0f75dc2777f4c971fbd44f848795f746'
ROCK_INSTALL_ORDER='lua-cjson-2.1.0.10-1.src.rock:lua-cjson:2.1.0.10-1
luafilesystem-1.9.0-1.src.rock:luafilesystem:1.9.0-1
luasocket-3.1.0-1.src.rock:luasocket:3.1.0-1
mimetypes-1.1.0-2.src.rock:mimetypes:1.1.0-2
lzlib-0.4.1.53-4.src.rock:lzlib:0.4.1.53-4
pegasus-1.1.0-0.src.rock:pegasus:1.1.0-0'
LSQLITE3_SOURCE=lsqlite3-0.9.6.c
LSQLITE3_SHA256=a3de0d56dcdd7df85e334174cd46e70451f996bc843e735ab1d8a8e8804f9486
LSQLITE3_URL=https://raw.githubusercontent.com/abramov7613/lsqlite3-mirror/72cf3d38f6df7ac995f6db05d8ffeb78c25c9179/lsqlite3.c
SQLITE_ZIP=sqlite-amalgamation-3530200.zip
SQLITE_SHA256=8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32

LUAROCKS=${LUAI_CI_LUAROCKS:-}
if [ -z "$LUAROCKS" ]; then
    if [ -x /usr/bin/luarocks-5.4 ]; then
        LUAROCKS=/usr/bin/luarocks-5.4
    else
        LUAROCKS=$(command -v luarocks || true)
    fi
fi
[ -n "$LUAROCKS" ] && [ -x "$LUAROCKS" ] || {
    echo "LuaRocks for Lua 5.4 is required" >&2
    exit 2
}

verify_sha256() {
    verify_file=$1
    verify_expected=$2
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s  %s\n' "$verify_expected" "$verify_file" \
            | sha256sum -c - >/dev/null
    else
        verify_actual=$(shasum -a 256 "$verify_file" | awk '{ print $1 }')
        [ "$verify_actual" = "$verify_expected" ]
    fi
}

stage() {
    stage_url=$1
    stage_file=$2
    stage_expected=$3
    if [ -f "$stage_file" ] \
        && verify_sha256 "$stage_file" "$stage_expected"; then
        return
    fi
    stage_temporary=$stage_file.part.$$
    rm -f "$stage_temporary"
    trap 'rm -f "$stage_temporary"' EXIT HUP INT TERM
    curl -fsSL --retry 5 --retry-delay 2 --retry-all-errors \
        --connect-timeout 30 --max-time 240 \
        "$stage_url" -o "$stage_temporary"
    verify_sha256 "$stage_temporary" "$stage_expected"
    mv -f "$stage_temporary" "$stage_file"
    trap - EXIT HUP INT TERM
}

load_check() {
    module=$1
    LD_LIBRARY_PATH="$PREFIX/lib" \
    LUA_CPATH="$ROCK_LIB_DIR/?.so;$ROCK_LIB_DIR/?/init.so;;" \
        "$PREFIX/bin/lua" -e "assert(require('$module'))" \
        >/dev/null
}

mkdir -p "$WORK" "$TREE"
ROCK_LUA_DIR=$("$LUAROCKS" --lua-dir="$PREFIX" --tree="$TREE" \
    config deploy_lua_dir)
ROCK_LIB_DIR=$("$LUAROCKS" --lua-dir="$PREFIX" --tree="$TREE" \
    config deploy_lib_dir)
for deploy_dir in "$ROCK_LUA_DIR" "$ROCK_LIB_DIR"; do
    case "$deploy_dir" in
        "$TREE"/*) ;;
        *) echo "LuaRocks deploy directory escapes the CI tree: $deploy_dir" >&2; exit 2 ;;
    esac
done
mkdir -p "$ROCK_LUA_DIR" "$ROCK_LIB_DIR"
BUILD=$WORK/build
mkdir -p "$BUILD"

printf '%s\n' "$ROCK_SOURCES" \
    | while IFS=: read -r rock digest; do
        stage "$ROCK_MIRROR/$rock" "$WORK/$rock" "$digest"
    done

printf '%s\n' "$ROCK_INSTALL_ORDER" \
    | while IFS=: read -r rock package version; do
        "$LUAROCKS" --lua-dir="$PREFIX" --tree="$TREE" \
            install --deps-mode=none "$WORK/$rock"
        "$LUAROCKS" --lua-dir="$PREFIX" --tree="$TREE" \
            show "$package" "$version" >/dev/null
        printf '%s %s ok\n' "$package" "$version"
    done

stage "$LSQLITE3_URL" "$WORK/$LSQLITE3_SOURCE" "$LSQLITE3_SHA256"
stage "https://dev-www.libreoffice.org/src/$SQLITE_ZIP" \
    "$WORK/$SQLITE_ZIP" "$SQLITE_SHA256"
rm -rf "$BUILD/sqlite-src"
unzip -q "$WORK/$SQLITE_ZIP" -d "$BUILD/sqlite-src"
cc -std=c11 -O2 -shared -fPIC \
    -I"$PREFIX/include" -I"$BUILD/sqlite-src/sqlite-amalgamation-3530200" \
    -DLSQLITE_VERSION=\"0.9.6\" \
    "$WORK/$LSQLITE3_SOURCE" \
    "$BUILD/sqlite-src/sqlite-amalgamation-3530200/sqlite3.c" \
    -o "$ROCK_LIB_DIR/lsqlite3.so" -ldl -lm -pthread
load_check lsqlite3
printf '%s\n' 'lsqlite3 ok'

LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
LUA_PATH="$ROCK_LUA_DIR/?.lua;$ROCK_LUA_DIR/?/init.lua;;" \
LUA_CPATH="$ROCK_LIB_DIR/?.so;$ROCK_LIB_DIR/?/init.so;;" \
    "$PREFIX/bin/lua" -e '
local cjson = require("cjson")
assert(cjson.decode(cjson.encode({ value = 17 })).value == 17)
assert(type(require("lfs").currentdir()) == "string")
assert(type(require("socket.core")) == "table")
assert(type(require("mimetypes")) == "table")
assert(type(require("zlib")) == "table")
assert(type(require("pegasus")) == "table")
assert(type(require("lsqlite3")) == "table")
' >/dev/null

if [ -n "${GITHUB_ENV:-}" ]; then
    {
        printf 'LUA_PATH=%s/?.lua;%s/?/init.lua;;\n' \
            "$ROCK_LUA_DIR" "$ROCK_LUA_DIR"
        printf 'LUA_CPATH=%s/?.so;%s/?/init.so;;\n' \
            "$ROCK_LIB_DIR" "$ROCK_LIB_DIR"
        printf 'LD_LIBRARY_PATH=%s:%s/lib%s\n' \
            "$ROCK_LIB_DIR" "$PREFIX" \
            "${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    } >> "$GITHUB_ENV"
fi

printf '%s\n' 'sample deps ok'
