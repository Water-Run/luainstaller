#!/bin/sh
set -eu

# Native LuaJIT release gate. Keep the official-Lua matrix independent.
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
CONFIGURATION=${LUAI_JIT_CONFIGURATION:-default}
case "$CONFIGURATION" in
    default) flags= ;;
    lua52compat) flags=-DLUAJIT_ENABLE_LUA52COMPAT ;;
    nogc64) flags=-DLUAJIT_DISABLE_GC64 ;;
    *) echo "unknown LuaJIT configuration: $CONFIGURATION" >&2; exit 2 ;;
esac
commit=$(sed -n 's/^commit=//p' "$PROJECT_ROOT/tools/luajit-version.txt")
checksum=$(sed -n 's/^sha256=//p' "$PROJECT_ROOT/tools/luajit-version.txt")
version=$(sed -n 's/^version=//p' "$PROJECT_ROOT/tools/luajit-version.txt")
case "$commit$checksum" in *[!0-9a-f]*) echo 'invalid LuaJIT source pin' >&2; exit 2 ;; esac
[ "${#commit}" -eq 40 ] && [ "${#checksum}" -eq 64 ]
work_root=$(mktemp -d /tmp/luainstaller-luajit.XXXXXX)
trap 'rm -rf -- "$work_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM
cp "$PROJECT_ROOT/tools/luajit-suites.txt" "$work_root/suites.txt"
evidence_dir=${LUAI_JIT_EVIDENCE_DIR:-/tmp/luainstaller-luajit-evidence}
if [ -L "$evidence_dir" ]; then echo 'evidence directory is a link' >&2; exit 2; fi
if [ ! -e "$evidence_dir" ]; then mkdir -m 700 -- "$evidence_dir"; fi
[ -d "$evidence_dir" ] && [ -O "$evidence_dir" ]
log=$(mktemp "$evidence_dir/$CONFIGURATION.XXXXXX.log")

set +e
(
    set -e
    printf 'LuaJIT source: %s\nSHA256: %s\nConfiguration: %s\n' "$commit" "$checksum" "$CONFIGURATION"
    curl --fail --location --retry 3 --connect-timeout 20 --max-time 180 \
        "https://codeload.github.com/LuaJIT/LuaJIT/tar.gz/$commit" -o "$work_root/source.tar.gz"
    printf '%s  %s\n' "$checksum" "$work_root/source.tar.gz" | sha256sum --check -
    tar -xzf "$work_root/source.tar.gz" -C "$work_root"
    prefix=$work_root/prefix
    make -C "$work_root/LuaJIT-$commit" -j2 PREFIX="$prefix" XCFLAGS="$flags"
    make -C "$work_root/LuaJIT-$commit" install PREFIX="$prefix"
    export LUAI_TEST_LUA="$prefix/bin/luajit"
    export LUAI_LUA="$LUAI_TEST_LUA"
    export LUAI_LUA_PREFIX="$prefix"
    export LUA_PATH=';;' LUA_CPATH=';;'
    export LUAI_JIT_RELEASE="$version" LUAI_JIT_SOURCE_COMMIT="$commit" LUAI_JIT_SOURCE_SHA256="$checksum"
    export LUAI_JIT_CONFIGURATION="$CONFIGURATION"
    cd "$PROJECT_ROOT"
    "$LUAI_TEST_LUA" -e 'assert(jit.version == "LuaJIT " .. os.getenv("LUAI_JIT_RELEASE")); print(jit.version, jit.os, jit.arch)'
    while IFS= read -r suite; do
        case "$suite" in ''|*[!a-z0-9_]*) echo 'invalid LuaJIT suite name' >&2; exit 2 ;; esac
        printf '\nRUN %s\n' "$suite"
        "$LUAI_TEST_LUA" "test/$suite.lua" < /dev/null
    done < "$work_root/suites.txt"
    "$LUAI_TEST_LUA" test/no_lua_target.lua < /dev/null
    printf 'PASS luainstaller 1.8.2 LuaJIT %s %s\n' "$version" "$CONFIGURATION"
) >"$log" 2>&1
status=$?
set -e
if [ "$status" -eq 0 ]; then
    tail -n 1 "$log"
else
    tail -n 100 "$log"
    exit "$status"
fi
