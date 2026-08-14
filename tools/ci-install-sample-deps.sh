#!/bin/sh
set -eu

# Build the pinned native sample dependencies (lua-cjson, luafilesystem,
# lsqlite3) directly against the CI Lua prefix. Source inputs, digests, and
# compile recipes mirror the release matrix (tools/test-lua-versions.sh and
# docs/TESTING.adoc); downloads are SHA-256 verified. Each module builds and
# load-checks as soon as its sources are staged, so a single unreachable
# mirror fails the step loudly instead of leaving a half-built tree.

PREFIX=${LUAI_CI_LUA_PREFIX:-$HOME/luai-lua}
TREE=${LUAI_CI_ROCKS_TREE:-$HOME/luai-rocks}
WORK=${LUAI_CI_WORK:-/tmp/luai-ci-deps}
ABI=5.4

CJSON_ROCK=lua-cjson-2.1.0.10-1.src.rock
CJSON_SHA256=02dea368d07753647c75bd9e6660dd4d06ff7d09956d90d5afc4c3f5b78ed187
LFS_ROCK=luafilesystem-1.9.0-1.src.rock
LFS_SHA256=3de68d619f6ad95a27f4728814375447d921305194b7050dee6199057c31282f
LSQLITE3_ZIP=lsqlite3_v096.zip
LSQLITE3_SHA256=ecc6e7636a54f021bca5b4a01b35af06fd7a6fc8b21c4b3eccd4fdb5dd32ad82
SQLITE_ZIP=sqlite-amalgamation-3530200.zip
SQLITE_SHA256=8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32

verify_sha256() {
    file=$1
    expected=$2
    if command -v sha256sum >/dev/null 2>&1; then
        printf '%s  %s\n' "$expected" "$file" | sha256sum -c - >/dev/null
    else
        actual=$(shasum -a 256 "$file" | awk '{ print $1 }')
        [ "$actual" = "$expected" ]
    fi
}

stage() {
    url=$1
    file=$2
    expected=$3
    if [ ! -f "$file" ]; then
        curl -fsSL "$url" -o "$file"
    fi
    verify_sha256 "$file" "$expected"
}

load_check() {
    module=$1
    LD_LIBRARY_PATH="$PREFIX/lib" LUA_CPATH="$TREE/lib/lua/$ABI/?.so;;" \
        "$PREFIX/bin/lua" -e "assert(require('$module'))" \
        >/dev/null
}

mkdir -p "$WORK" "$TREE/lib/lua/$ABI"
BUILD=$WORK/build
mkdir -p "$BUILD"

stage "https://luarocks.org/$CJSON_ROCK" "$WORK/$CJSON_ROCK" "$CJSON_SHA256"
rm -rf "$BUILD/cjson"
unzip -q "$WORK/$CJSON_ROCK" -d "$BUILD/cjson"
cc -O2 -shared -fPIC -I"$PREFIX/include" \
    "$BUILD/cjson/lua-cjson/lua_cjson.c" \
    "$BUILD/cjson/lua-cjson/strbuf.c" \
    "$BUILD/cjson/lua-cjson/fpconv.c" \
    -o "$TREE/lib/lua/$ABI/cjson.so" -lm
load_check cjson
printf '%s\n' 'cjson ok'

stage "https://luarocks.org/$LFS_ROCK" "$WORK/$LFS_ROCK" "$LFS_SHA256"
rm -rf "$BUILD/lfs"
unzip -q "$WORK/$LFS_ROCK" -d "$BUILD/lfs"
cc -O2 -shared -fPIC -I"$PREFIX/include" \
    "$BUILD/lfs/luafilesystem/src/lfs.c" \
    -o "$TREE/lib/lua/$ABI/lfs.so"
load_check lfs
printf '%s\n' 'lfs ok'

stage 'https://lua.sqlite.org/home/zip/lsqlite3_v096.zip?uuid=v0.9.6' \
    "$WORK/$LSQLITE3_ZIP" "$LSQLITE3_SHA256"
stage "https://www.sqlite.org/2026/$SQLITE_ZIP" "$WORK/$SQLITE_ZIP" "$SQLITE_SHA256"
rm -rf "$BUILD/lsqlite3-src" "$BUILD/sqlite-src"
unzip -q "$WORK/$LSQLITE3_ZIP" -d "$BUILD/lsqlite3-src"
unzip -q "$WORK/$SQLITE_ZIP" -d "$BUILD/sqlite-src"
cc -std=c11 -O2 -shared -fPIC \
    -I"$PREFIX/include" -I"$BUILD/sqlite-src/sqlite-amalgamation-3530200" \
    -DLSQLITE_VERSION=\"0.9.6\" \
    "$BUILD/lsqlite3-src/lsqlite3_v096/lsqlite3.c" \
    "$BUILD/sqlite-src/sqlite-amalgamation-3530200/sqlite3.c" \
    -o "$TREE/lib/lua/$ABI/lsqlite3.so" -ldl -lm -pthread
load_check lsqlite3
printf '%s\n' 'lsqlite3 ok'

printf '%s\n' 'sample deps ok'
