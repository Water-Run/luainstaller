#!/bin/sh
set -eu

LINUX_X64=${LINUX_X64:-"waterrun@192.168.10.40"}
LINUX_X64_PORT=${LINUX_X64_PORT:-"22222"}
LINUX_ARM64=${LINUX_ARM64:-"lyf@192.168.5.19"}
REMOTE_ROOT=${REMOTE_ROOT:-"/tmp/luainstaller-linux-current"}
SOURCE_CACHE=${SOURCE_CACHE:-"/tmp/luainstaller-source-cache"}
ARM_LUA_PREFIX=${ARM_LUA_PREFIX:-"/tmp/luainstaller-linux-arm64-lua"}
ARM_LUAROCKS_PREFIX=${ARM_LUAROCKS_PREFIX:-"/tmp/luainstaller-linux-arm64-luarocks"}
ARM_ROCKTREE=${ARM_ROCKTREE:-"/tmp/luainstaller-linux-arm64-rocktree"}
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LUA_TARBALL=lua-5.4.8.tar.gz
LUA_URL=https://www.lua.org/ftp/$LUA_TARBALL
LUAROCKS_TARBALL=luarocks-3.12.2.tar.gz
LSQLITE3_ZIP=lsqlite3_v096.zip
SQLITE_ZIP=sqlite-amalgamation-3530200.zip
LUA_SHA256=4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
LUAROCKS_SHA256=b0e0c85205841ddd7be485f53d6125766d18a81d226588d2366931e9a1484492
LSQLITE3_SHA256=ecc6e7636a54f021bca5b4a01b35af06fd7a6fc8b21c4b3eccd4fdb5dd32ad82
SQLITE_SHA256=8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32

require_safe_tmp_path() {
    path=$1
    case "$path" in
        /tmp/luainstaller-?*) ;;
        *)
            echo "unsafe temporary path: $path" >&2
            exit 2
            ;;
    esac
    case "$path" in
        *[!A-Za-z0-9._/-]*)
            echo "unsafe characters in temporary path: $path" >&2
            exit 2
            ;;
    esac
    case "$path" in
        *'/../'*|*'/..'|*'/./'*|*'/.'|*'//'*)
            echo "non-normalized temporary path: $path" >&2
            exit 2
            ;;
    esac
}

stage_source() {
    name=$1
    url=$2
    expected=$3
    destination=$SOURCE_CACHE/$name
    if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -f "$destination" ]; }; then
        echo "unsafe source-cache entry: $destination" >&2
        exit 1
    fi
    if [ -f "$destination" ] \
        && ! printf '%s  %s\n' "$expected" "$destination" | sha256sum -c - >/dev/null 2>&1; then
        rm -f "$destination"
    fi
    if [ ! -f "$destination" ]; then
        part=$destination.part.$$
        rm -f "$part"
        trap 'rm -f "$part"' EXIT HUP INT TERM
        curl -fL --connect-timeout 20 --max-time 180 -o "$part" "$url"
        printf '%s  %s\n' "$expected" "$part" | sha256sum -c -
        mv "$part" "$destination"
        trap - EXIT HUP INT TERM
    fi
}

create_tracked_tree_archive() {
    TRACKED_LIST=$SOURCE_CACHE/tracked-files.$$.list
    TRACKED_ARCHIVE=$SOURCE_CACHE/tracked-tree.$$.tar
    rm -f "$TRACKED_LIST" "$TRACKED_ARCHIVE"
    (cd "$PROJECT_ROOT" && git ls-files -z) >"$TRACKED_LIST"
    (cd "$PROJECT_ROOT" && tar --null -T "$TRACKED_LIST" -cf "$TRACKED_ARCHIVE")
    rm -f "$TRACKED_LIST"
}

quote_remote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

copy_tree_ssh() {
    target=$1
    port=$2
    remote_root=$3
    quoted_root=$(quote_remote "$remote_root")
    # shellcheck disable=SC2029 # quoted_root is deliberately expanded and shell-quoted locally.
    ssh -p "$port" "$target" \
        "rm -rf $quoted_root && mkdir -p $quoted_root && tar -xf - -C $quoted_root" \
        <"$TRACKED_ARCHIVE"
}

copy_tree_default_ssh() {
    target=$1
    remote_root=$2
    quoted_root=$(quote_remote "$remote_root")
    # shellcheck disable=SC2029 # quoted_root is deliberately expanded and shell-quoted locally.
    ssh "$target" \
        "rm -rf $quoted_root && mkdir -p $quoted_root && tar -xf - -C $quoted_root" \
        <"$TRACKED_ARCHIVE"
}

for safe_path in "$REMOTE_ROOT" "$SOURCE_CACHE" "$ARM_LUA_PREFIX" \
    "$ARM_LUAROCKS_PREFIX" "$ARM_ROCKTREE"; do
    require_safe_tmp_path "$safe_path"
done
command -v git >/dev/null 2>&1 || { echo "missing command: git" >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { echo "missing command: sha256sum" >&2; exit 1; }
umask 077
if [ -L "$SOURCE_CACHE" ] || { [ -e "$SOURCE_CACHE" ] && [ ! -d "$SOURCE_CACHE" ]; }; then
    echo "unsafe source-cache directory: $SOURCE_CACHE" >&2
    exit 1
fi
mkdir -p "$SOURCE_CACHE"
# shellcheck disable=SC2012 # Path characters are validated; numeric ls is portable across target hosts.
cache_owner=$(LC_ALL=C ls -dn "$SOURCE_CACHE" | awk '{ print $3 }')
test "$cache_owner" = "$(id -u)" || { echo "source cache is not owned by this user" >&2; exit 1; }
chmod 700 "$SOURCE_CACHE"

stage_source "$LUA_TARBALL" "$LUA_URL" "$LUA_SHA256"
stage_source "$LUAROCKS_TARBALL" "https://luarocks.org/releases/$LUAROCKS_TARBALL" "$LUAROCKS_SHA256"
stage_source "$LSQLITE3_ZIP" 'https://lua.sqlite.org/home/zip/lsqlite3_v096.zip?uuid=v0.9.6' "$LSQLITE3_SHA256"
stage_source "$SQLITE_ZIP" 'https://www.sqlite.org/2026/sqlite-amalgamation-3530200.zip' "$SQLITE_SHA256"
create_tracked_tree_archive
trap 'rm -f "$TRACKED_LIST" "$TRACKED_ARCHIVE"' EXIT HUP INT TERM

copy_tree_ssh "$LINUX_X64" "$LINUX_X64_PORT" "$REMOTE_ROOT"

ssh -p "$LINUX_X64_PORT" "$LINUX_X64" "REMOTE_ROOT=$(quote_remote "$REMOTE_ROOT") sh -s" <<'EOF'
set -eu
cd "$REMOTE_ROOT"
test "$(lua -e 'io.write(_VERSION)')" = "Lua 5.4"
find src test -type f -name '*.lua' -print0 | xargs -0 -n1 luac -p
sh -n tools/install-source.sh
lua test/cli_split_smoke.lua
lua test/contract_docs.lua
lua test/production_edges.lua
smoke_output=$(lua test/smoke_all.lua)
printf '%s\n' "$smoke_output"
if printf '%s\n' "$smoke_output" | grep -i 'skipped' >/dev/null; then
    echo "linux x64 smoke suite reported a skipped probe" >&2
    exit 1
fi
rm -rf /tmp/luainstaller-linux-source-prefix /tmp/luainstaller-linux-runtime
sh tools/install-source.sh --prefix /tmp/luainstaller-linux-source-prefix
/tmp/luainstaller-linux-source-prefix/bin/luai -v
/tmp/luainstaller-linux-source-prefix/bin/luainstaller build --dir test/runtime_bundle/main.lua -o /tmp/luainstaller-linux-runtime --max-deps 120
output=$(env -i PATH=/usr/bin:/bin /tmp/luainstaller-linux-runtime/luainstaller-linux-runtime linux-clean)
printf '%s\n' "$output" | grep "hello linux-clean"
echo "linux x64 remote ok"
EOF

copy_tree_default_ssh "$LINUX_ARM64" "$REMOTE_ROOT"
scp "$SOURCE_CACHE/$LUA_TARBALL" "$SOURCE_CACHE/$LUAROCKS_TARBALL" \
    "$SOURCE_CACHE/$LSQLITE3_ZIP" "$SOURCE_CACHE/$SQLITE_ZIP" \
    "$LINUX_ARM64:/tmp/" >/dev/null

# shellcheck disable=SC2029 # Values are expanded locally only after quote_remote.
ssh "$LINUX_ARM64" "REMOTE_ROOT=$(quote_remote "$REMOTE_ROOT") ARM_LUA_PREFIX=$(quote_remote "$ARM_LUA_PREFIX") ARM_LUAROCKS_PREFIX=$(quote_remote "$ARM_LUAROCKS_PREFIX") ARM_ROCKTREE=$(quote_remote "$ARM_ROCKTREE") LUA_TARBALL=$(quote_remote "$LUA_TARBALL") LUAROCKS_TARBALL=$(quote_remote "$LUAROCKS_TARBALL") LSQLITE3_ZIP=$(quote_remote "$LSQLITE3_ZIP") SQLITE_ZIP=$(quote_remote "$SQLITE_ZIP") LUA_SHA256=$(quote_remote "$LUA_SHA256") LUAROCKS_SHA256=$(quote_remote "$LUAROCKS_SHA256") LSQLITE3_SHA256=$(quote_remote "$LSQLITE3_SHA256") SQLITE_SHA256=$(quote_remote "$SQLITE_SHA256") sh -s" <<'EOF'
set -eu
verify_source() {
    expected=$1
    source_path=$2
    printf '%s  %s\n' "$expected" "$source_path" | sha256sum -c - >/dev/null
}
verify_source "$LUA_SHA256" "/tmp/$LUA_TARBALL"
verify_source "$LUAROCKS_SHA256" "/tmp/$LUAROCKS_TARBALL"
verify_source "$LSQLITE3_SHA256" "/tmp/$LSQLITE3_ZIP"
verify_source "$SQLITE_SHA256" "/tmp/$SQLITE_ZIP"
cd "$REMOTE_ROOT"
find src test -type f -name '*.lua' -print0 | xargs -0 -n1 luac -p
sh -n tools/install-source.sh
lua test/cli_split_smoke.lua

if [ ! -f "$ARM_LUA_PREFIX/lib/liblua.so.5.4" ] \
    || [ ! -x "$ARM_LUA_PREFIX/bin/lua" ] \
    || ! "$ARM_LUA_PREFIX/bin/lua" -v 2>&1 | grep '^Lua 5\.4\.8 ' >/dev/null; then
    rm -rf "$ARM_LUA_PREFIX" /tmp/luainstaller-linux-arm64-lua-build
    mkdir -p "$ARM_LUA_PREFIX/bin" "$ARM_LUA_PREFIX/include" "$ARM_LUA_PREFIX/lib/pkgconfig" /tmp/luainstaller-linux-arm64-lua-build
    tar -xzf "/tmp/$LUA_TARBALL" -C /tmp/luainstaller-linux-arm64-lua-build
    cd /tmp/luainstaller-linux-arm64-lua-build/lua-5.4.8
    make linux MYCFLAGS=-fPIC >/tmp/luainstaller-linux-arm64-lua-build.log 2>&1
    objects=$(cd src && ar t liblua.a)
    (cd src && cc -shared -Wl,-soname,liblua.so.5.4 -o liblua.so.5.4 $objects -lm -ldl)
    cp src/lua.h src/luaconf.h src/lualib.h src/lauxlib.h src/lua.hpp "$ARM_LUA_PREFIX/include/"
    cp src/lua src/luac "$ARM_LUA_PREFIX/bin/"
    cp src/liblua.so.5.4 "$ARM_LUA_PREFIX/lib/"
    ln -s liblua.so.5.4 "$ARM_LUA_PREFIX/lib/liblua.so"
    cat >"$ARM_LUA_PREFIX/lib/pkgconfig/lua.pc" <<PC
prefix=$ARM_LUA_PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: Lua
Description: Lua language engine
Version: 5.4.8
Libs: -L\${libdir} -Wl,-rpath,\${libdir} -llua -lm -ldl
Cflags: -I\${includedir}
PC
    cd "$REMOTE_ROOT"
fi
test "$("$ARM_LUA_PREFIX/bin/lua" -e 'io.write(_VERSION)')" = "Lua 5.4"

if [ ! -x "$ARM_LUAROCKS_PREFIX/bin/luarocks" ] \
    || ! "$ARM_LUAROCKS_PREFIX/bin/luarocks" --version | grep '3\.12\.2' >/dev/null; then
    rm -rf "$ARM_LUAROCKS_PREFIX" /tmp/luainstaller-linux-arm64-luarocks-build
    mkdir -p /tmp/luainstaller-linux-arm64-luarocks-build
    tar -xzf "/tmp/$LUAROCKS_TARBALL" -C /tmp/luainstaller-linux-arm64-luarocks-build
    cd /tmp/luainstaller-linux-arm64-luarocks-build/luarocks-3.12.2
    ./configure --prefix="$ARM_LUAROCKS_PREFIX" --with-lua="$ARM_LUA_PREFIX" \
        >/tmp/luainstaller-linux-arm64-luarocks-configure.log
    make >/tmp/luainstaller-linux-arm64-luarocks-build.log
    make install >/tmp/luainstaller-linux-arm64-luarocks-install.log
    cd "$REMOTE_ROOT"
fi

DEPS_LUA_PATH="$ARM_ROCKTREE/share/lua/5.4/?.lua;$ARM_ROCKTREE/share/lua/5.4/?/init.lua;;"
DEPS_LUA_CPATH="$ARM_ROCKTREE/lib/lua/5.4/?.so;$ARM_ROCKTREE/lib/lua/5.4/?/init.so;;"
for required_command in cc pkg-config curl rg sha256sum "$ARM_LUAROCKS_PREFIX/bin/luarocks"; do
    command -v "$required_command" >/dev/null 2>&1 || {
        echo "missing ARM64 test command: $required_command" >&2
        exit 1
    }
done
deps_ready=true
for pinned_dependency in \
    'lua-cjson 2.1.0.10-1' \
    'luafilesystem 1.9.0-1' \
    'luasocket 3.1.0-1' \
    'mimetypes 1.1.0-2' \
    'pegasus 1.1.0-0'; do
    # Word splitting is intentional: luarocks show takes the name and version separately.
    if ! "$ARM_LUAROCKS_PREFIX/bin/luarocks" --tree "$ARM_ROCKTREE" \
        show $pinned_dependency >/dev/null 2>&1; then
        deps_ready=false
    fi
done
if [ "$deps_ready" != true ] \
    || ! LUA_PATH="$DEPS_LUA_PATH" LUA_CPATH="$DEPS_LUA_CPATH" "$ARM_LUA_PREFIX/bin/lua" \
    -e 'require("cjson"); require("lfs"); require("socket.core"); require("mimetypes"); require("pegasus")' \
    >/tmp/luainstaller-linux-arm64-native-check.log 2>&1; then
    rm -rf "$ARM_ROCKTREE"
    mkdir -p "$ARM_ROCKTREE"
    "$ARM_LUAROCKS_PREFIX/bin/luarocks" --tree "$ARM_ROCKTREE" install --force lua-cjson 2.1.0.10-1 \
        >/tmp/luainstaller-linux-arm64-cjson.log 2>&1
    "$ARM_LUAROCKS_PREFIX/bin/luarocks" --tree "$ARM_ROCKTREE" install --force luafilesystem 1.9.0-1 \
        >/tmp/luainstaller-linux-arm64-lfs.log 2>&1
    "$ARM_LUAROCKS_PREFIX/bin/luarocks" --tree "$ARM_ROCKTREE" install --force luasocket 3.1.0-1 \
        >/tmp/luainstaller-linux-arm64-luasocket.log 2>&1
    "$ARM_LUAROCKS_PREFIX/bin/luarocks" --tree "$ARM_ROCKTREE" install --force mimetypes 1.1.0-2 \
        >/tmp/luainstaller-linux-arm64-mimetypes.log 2>&1
    "$ARM_LUAROCKS_PREFIX/bin/luarocks" --tree "$ARM_ROCKTREE" install --force pegasus 1.1.0-0 \
        >/tmp/luainstaller-linux-arm64-pegasus.log 2>&1
fi
if ! LUA_PATH="$DEPS_LUA_PATH" LUA_CPATH="$DEPS_LUA_CPATH" "$ARM_LUA_PREFIX/bin/lua" \
    -e 'require("lsqlite3")' >/tmp/luainstaller-linux-arm64-lsqlite-check.log 2>&1; then
    rm -rf /tmp/luainstaller-linux-arm64-lsqlite-build
    mkdir -p /tmp/luainstaller-linux-arm64-lsqlite-build "$ARM_ROCKTREE/lib/lua/5.4"
    cd /tmp/luainstaller-linux-arm64-lsqlite-build
    unzip -q "/tmp/$LSQLITE3_ZIP" -d lsqlite3-src
    unzip -q "/tmp/$SQLITE_ZIP"
    lsqlite_file=$(find lsqlite3-src -name lsqlite3.c -print -quit)
    sqlite_file=$(find . -name sqlite3.c -print -quit)
    lsqlite_dir=$(dirname "$lsqlite_file")
    sqlite_dir=$(dirname "$sqlite_file")
    cc -shared -fPIC -I"$ARM_LUA_PREFIX/include" -I"$sqlite_dir" \
        -DLSQLITE_VERSION=\"0.9.6\" "$lsqlite_dir/lsqlite3.c" "$sqlite_dir/sqlite3.c" \
        -o "$ARM_ROCKTREE/lib/lua/5.4/lsqlite3.so"
    cd "$REMOTE_ROOT"
fi
LUA_PATH="$DEPS_LUA_PATH" LUA_CPATH="$DEPS_LUA_CPATH" "$ARM_LUA_PREFIX/bin/lua" \
    -e 'require("cjson"); require("lfs"); require("socket.core"); require("pegasus"); require("lsqlite3"); print("arm64 native deps ok")'

PATH="$ARM_LUAROCKS_PREFIX/bin:$ARM_LUA_PREFIX/bin:$PATH" LUA_PATH="$DEPS_LUA_PATH" LUA_CPATH="$DEPS_LUA_CPATH" \
    PKG_CONFIG_PATH="$ARM_LUA_PREFIX/lib/pkgconfig" lua test/contract_docs.lua
smoke_output=$(PATH="$ARM_LUAROCKS_PREFIX/bin:$ARM_LUA_PREFIX/bin:$PATH" \
    LUA_PATH="$DEPS_LUA_PATH" LUA_CPATH="$DEPS_LUA_CPATH" \
    PKG_CONFIG_PATH="$ARM_LUA_PREFIX/lib/pkgconfig" lua test/smoke_all.lua)
printf '%s\n' "$smoke_output"
if printf '%s\n' "$smoke_output" | grep -i 'skipped' >/dev/null; then
    echo "ARM64 smoke suite reported a skipped probe" >&2
    exit 1
fi

rm -rf /tmp/luainstaller-linux-arm64-source-prefix /tmp/luainstaller-linux-arm64-runtime \
    /tmp/luainstaller-linux-arm64-runtime-onefile /tmp/luainstaller-linux-arm64-cache \
    /tmp/luainstaller-linux-arm64-link
sh tools/install-source.sh --lua "$ARM_LUA_PREFIX/bin/lua" \
    --prefix /tmp/luainstaller-linux-arm64-source-prefix
/tmp/luainstaller-linux-arm64-source-prefix/bin/luai -v
/tmp/luainstaller-linux-arm64-source-prefix/bin/luai -a test/runtime_bundle/main.lua --max-deps 120
PKG_CONFIG_PATH="$ARM_LUA_PREFIX/lib/pkgconfig" \
    /tmp/luainstaller-linux-arm64-source-prefix/bin/luainstaller build --dir \
    test/runtime_bundle/main.lua -o /tmp/luainstaller-linux-arm64-runtime --max-deps 120
output=$(env -i PATH=/usr/bin:/bin /tmp/luainstaller-linux-arm64-runtime/luainstaller-linux-arm64-runtime arm64-clean)
printf '%s\n' "$output" | grep "hello arm64-clean"

ln -s /tmp/luainstaller-linux-arm64-runtime/luainstaller-linux-arm64-runtime \
    /tmp/luainstaller-linux-arm64-link
output=$(env -i PATH=/usr/bin:/bin /tmp/luainstaller-linux-arm64-link arm64-symlink)
printf '%s\n' "$output" | grep "hello arm64-symlink"

PKG_CONFIG_PATH="$ARM_LUA_PREFIX/lib/pkgconfig" \
    /tmp/luainstaller-linux-arm64-source-prefix/bin/luainstaller build --file \
    test/runtime_bundle/main.lua -o /tmp/luainstaller-linux-arm64-runtime-onefile --max-deps 120
mkdir -m 700 /tmp/luainstaller-linux-arm64-cache
output=$(env -i PATH=/usr/bin:/bin TMPDIR=/tmp/luainstaller-linux-arm64-cache \
    /tmp/luainstaller-linux-arm64-runtime-onefile arm64-onefile)
printf '%s\n' "$output" | grep "hello arm64-onefile"

pids=""
i=1
while [ "$i" -le 12 ]; do
    env -i PATH=/usr/bin:/bin TMPDIR=/tmp/luainstaller-linux-arm64-cache \
        /tmp/luainstaller-linux-arm64-runtime-onefile "arm64-concurrent-$i" \
        >"/tmp/luainstaller-linux-arm64-concurrent-$i.log" 2>&1 &
    pids="$pids $!"
    i=$((i + 1))
done
for pid in $pids; do
    wait "$pid"
done
i=1
while [ "$i" -le 12 ]; do
    grep "hello arm64-concurrent-$i" "/tmp/luainstaller-linux-arm64-concurrent-$i.log"
    i=$((i + 1))
done

manifest=$(find /tmp/luainstaller-linux-arm64-cache -path '*/.luai/manifest.lua' | head -n 1)
inner=$(find /tmp/luainstaller-linux-arm64-cache -type f -name inner -perm /111 | head -n 1)
test -n "$manifest"
test -n "$inner"
chmod -x "$inner"
output=$(env -i PATH=/usr/bin:/bin TMPDIR=/tmp/luainstaller-linux-arm64-cache \
    /tmp/luainstaller-linux-arm64-runtime-onefile arm64-mode-repair)
printf '%s\n' "$output" | grep "hello arm64-mode-repair"
test -x "$inner"
echo "linux arm64 remote ok"
EOF
