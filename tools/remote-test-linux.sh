#!/bin/sh
set -eu

LINUX_X64=${LINUX_X64:-"waterrun@192.168.10.40"}
LINUX_X64_PORT=${LINUX_X64_PORT:-"22222"}
LINUX_DEBIAN=${LINUX_DEBIAN:-"yynicepc@192.168.10.57"}
LINUX_DEBIAN_PORT=${LINUX_DEBIAN_PORT:-"26022"}
LINUX_ARM64=${LINUX_ARM64:-"lyf@192.168.5.19"}
REMOTE_ROOT=${REMOTE_ROOT:-"/tmp/luainstaller-linux-current"}
DEBIAN_ROOT=${DEBIAN_ROOT:-"/tmp/luainstaller-debian-current"}
SOURCE_CACHE=${SOURCE_CACHE:-"/tmp/luainstaller-source-cache"}
MATRIX_WORK_ROOT=${MATRIX_WORK_ROOT:-"/tmp/luainstaller-lua-matrix"}
MATRIX_SOURCE_CACHE=${MATRIX_SOURCE_CACHE:-"/tmp/luainstaller-source-cache"}
MATRIX_EVIDENCE_ROOT=${MATRIX_EVIDENCE_ROOT:-"/tmp/luainstaller-lua-evidence"}
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TRACKED_ARCHIVE=

require_no_symlink_ancestors() {
    candidate=$1
    remainder=${candidate#/tmp/}
    current=/tmp
    saved_ifs=$IFS
    IFS=/
    # shellcheck disable=SC2086 # The validated path is intentionally split on '/'.
    set -- $remainder
    IFS=$saved_ifs
    for component do
        current=$current/$component
        if [ -L "$current" ]; then
            echo "unsafe symlink ancestor in temporary path: $current" >&2
            exit 2
        fi
        if [ -e "$current" ] && [ ! -d "$current" ]; then
            echo "unsafe non-directory ancestor in temporary path: $current" >&2
            exit 2
        fi
        [ -e "$current" ] || break
    done
}

require_safe_tmp_path() {
    path=$1
    case "$path" in
        /tmp/luainstaller-?*) ;;
        *) echo "unsafe temporary path: $path" >&2; exit 2 ;;
    esac
    case "$path" in
        *[!A-Za-z0-9._/-]*|*'/../'*|*'/..'|*'/./'*|*'/.'|*'//'*)
            echo "unsafe temporary path: $path" >&2
            exit 2
            ;;
    esac
    require_no_symlink_ancestors "$path"
}

quote_remote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

check_remote_tmp_path() {
    target=$1
    port=$2
    checked_path=$3
    quoted_path=$(quote_remote "$checked_path")
    if [ -n "$port" ]; then
        # shellcheck disable=SC2029 # checked_path is validated and shell-quoted locally.
        ssh -p "$port" "$target" "CHECK_PATH=$quoted_path sh -s" <<'EOF'
set -eu
path=$CHECK_PATH
remainder=${path#/tmp/}
current=/tmp
saved_ifs=$IFS
IFS=/
set -- $remainder
IFS=$saved_ifs
for component do
    current=$current/$component
    if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
        echo "unsafe remote temporary-path ancestor: $current" >&2
        exit 2
    fi
    [ -e "$current" ] || break
done
if [ -e "$path" ]; then
    owner=$(LC_ALL=C ls -dn "$path" | awk '{ print $3 }')
    test "$owner" = "$(id -u)" || {
        echo "remote temporary path is not owned by this user: $path" >&2
        exit 2
    }
fi
EOF
    else
        # shellcheck disable=SC2029 # checked_path is validated and shell-quoted locally.
        ssh "$target" "CHECK_PATH=$quoted_path sh -s" <<'EOF'
set -eu
path=$CHECK_PATH
remainder=${path#/tmp/}
current=/tmp
saved_ifs=$IFS
IFS=/
set -- $remainder
IFS=$saved_ifs
for component do
    current=$current/$component
    if [ -L "$current" ] || { [ -e "$current" ] && [ ! -d "$current" ]; }; then
        echo "unsafe remote temporary-path ancestor: $current" >&2
        exit 2
    fi
    [ -e "$current" ] || break
done
if [ -e "$path" ]; then
    owner=$(LC_ALL=C ls -dn "$path" | awk '{ print $3 }')
    test "$owner" = "$(id -u)" || {
        echo "remote temporary path is not owned by this user: $path" >&2
        exit 2
    }
fi
EOF
    fi
}

create_tracked_tree_archive() {
    TRACKED_ARCHIVE=$SOURCE_CACHE/tracked-tree.$$.tar
    rm -f "$TRACKED_ARCHIVE"
    (cd "$PROJECT_ROOT" && git -c tar.umask=0022 archive --format=tar HEAD) \
        >"$TRACKED_ARCHIVE"
}

copy_tree_ssh() {
    target=$1
    port=$2
    remote_root=$3
    quoted_root=$(quote_remote "$remote_root")
    # shellcheck disable=SC2029 # quoted_root is validated and shell-quoted locally.
    ssh -p "$port" "$target" \
        "rm -rf $quoted_root && mkdir -m 700 -p $quoted_root && tar -xpf - -C $quoted_root" \
        <"$TRACKED_ARCHIVE"
}

copy_tree_default_ssh() {
    target=$1
    remote_root=$2
    quoted_root=$(quote_remote "$remote_root")
    # shellcheck disable=SC2029 # quoted_root is validated and shell-quoted locally.
    ssh "$target" \
        "rm -rf $quoted_root && mkdir -m 700 -p $quoted_root && tar -xpf - -C $quoted_root" \
        <"$TRACKED_ARCHIVE"
}

cleanup_local() {
    if [ -n "$TRACKED_ARCHIVE" ]; then
        rm -f "$TRACKED_ARCHIVE"
    fi
}

for safe_path in "$REMOTE_ROOT" "$DEBIAN_ROOT" "$SOURCE_CACHE" \
    "$MATRIX_WORK_ROOT" "$MATRIX_SOURCE_CACHE" "$MATRIX_EVIDENCE_ROOT"; do
    require_safe_tmp_path "$safe_path"
done
for command in awk chmod git id ls mkdir rm sed ssh tar; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "missing command: $command" >&2
        exit 1
    }
done
umask 077
if [ -L "$SOURCE_CACHE" ] || { [ -e "$SOURCE_CACHE" ] && [ ! -d "$SOURCE_CACHE" ]; }; then
    echo "unsafe source-cache directory: $SOURCE_CACHE" >&2
    exit 1
fi
mkdir -p "$SOURCE_CACHE"
# shellcheck disable=SC2012 # Numeric ls output is portable on the tested hosts.
cache_owner=$(LC_ALL=C ls -dn "$SOURCE_CACHE" | awk '{ print $3 }')
test "$cache_owner" = "$(id -u)" || {
    echo "source cache is not owned by this user" >&2
    exit 1
}
chmod 700 "$SOURCE_CACHE"
trap cleanup_local EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
create_tracked_tree_archive

for remote_path in "$REMOTE_ROOT" "$MATRIX_WORK_ROOT" "$MATRIX_SOURCE_CACHE" \
    "$MATRIX_EVIDENCE_ROOT"; do
    check_remote_tmp_path "$LINUX_X64" "$LINUX_X64_PORT" "$remote_path"
done
copy_tree_ssh "$LINUX_X64" "$LINUX_X64_PORT" "$REMOTE_ROOT"

# shellcheck disable=SC2029 # Every expanded value is validated and shell-quoted locally.
ssh -p "$LINUX_X64_PORT" "$LINUX_X64" \
    "REMOTE_ROOT=$(quote_remote "$REMOTE_ROOT") MATRIX_WORK_ROOT=$(quote_remote "$MATRIX_WORK_ROOT") MATRIX_SOURCE_CACHE=$(quote_remote "$MATRIX_SOURCE_CACHE") MATRIX_EVIDENCE_ROOT=$(quote_remote "$MATRIX_EVIDENCE_ROOT") sh -s" <<'EOF'
set -eu
command -v renice >/dev/null 2>&1 && renice 15 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1 || true
TEST_ROOT=/tmp/luainstaller-linux-x64-run-$$
EMPTY_PATH=$TEST_ROOT/empty-path
INSTALL_ROOT=$TEST_ROOT/install
RUNTIME_ROOT=$TEST_ROOT/runtime

cleanup_test_artifacts() {
    rm -rf "$TEST_ROOT"
}
case "$TEST_ROOT" in /tmp/luainstaller-linux-x64-run-[0-9]*) ;; *) exit 2 ;; esac
test ! -e "$TEST_ROOT" && test ! -L "$TEST_ROOT"
mkdir -m 700 "$TEST_ROOT"
mkdir -m 700 "$EMPTY_PATH"
trap cleanup_test_artifacts EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$REMOTE_ROOT"
LUAI_MATRIX_EDGE_COVERAGE_MODE=available \
    HOST_LABEL=rocky-x86_64 WORK_ROOT="$MATRIX_WORK_ROOT" \
    SOURCE_CACHE="$MATRIX_SOURCE_CACHE" EVIDENCE_DIR="$MATRIX_EVIDENCE_ROOT" \
    sh tools/test-lua-versions.sh

LUA_PREFIX=$MATRIX_WORK_ROOT/lua-5.4.8
LUAROCKS_PREFIX=$MATRIX_WORK_ROOT/luarocks-5.4.8
NATIVE_DEPS=$MATRIX_WORK_ROOT/native-deps-5.4.8
TEST_LUA=$LUA_PREFIX/bin/lua
TEST_LUAC=$LUA_PREFIX/bin/luac
TEST_LUAROCKS=$LUAROCKS_PREFIX/bin/luarocks
DEPS_LUA_PATH=$NATIVE_DEPS/share/lua/5.4/?.lua\;$NATIVE_DEPS/share/lua/5.4/?/init.lua
DEPS_LUA_CPATH=$NATIVE_DEPS/lib/lua/5.4/?.so\;$NATIVE_DEPS/lib/lua/5.4/?/init.so
test "$($TEST_LUA -e 'io.write(_VERSION)')" = "Lua 5.4"
test "$(PKG_CONFIG_PATH="$LUA_PREFIX/lib/pkgconfig" pkg-config --modversion lua)" = "5.4.8"
find src test tools -type f -name '*.lua' -print | while IFS= read -r file; do
    "$TEST_LUAC" -p "$file"
done

PATH=$LUAROCKS_PREFIX/bin:$LUA_PREFIX/bin:/usr/bin:/bin
LUA_PATH=$DEPS_LUA_PATH
LUA_CPATH=$DEPS_LUA_CPATH
LUAI_TEST_LUA=$TEST_LUA
LUAI_TEST_LUAC=$TEST_LUAC
LUAI_LUA_PREFIX=$LUA_PREFIX
LUAI_LUA_RELEASE=5.4.8
PKG_CONFIG_PATH=$LUA_PREFIX/lib/pkgconfig
export PATH LUA_PATH LUA_CPATH LUAI_TEST_LUA LUAI_TEST_LUAC
export LUAI_LUA_PREFIX LUAI_LUA_RELEASE PKG_CONFIG_PATH

"$TEST_LUAROCKS" make --force --deps-mode=none --tree "$INSTALL_ROOT" \
    luainstaller-1.0.0-1.rockspec
"$INSTALL_ROOT/bin/luai" -v
"$INSTALL_ROOT/bin/luainstaller" build --dir test/runtime_bundle/main.lua \
    -o "$RUNTIME_ROOT" --max-deps 120
output=$(env -i PATH="$EMPTY_PATH" "$RUNTIME_ROOT/$(basename "$RUNTIME_ROOT")" linux-clean)
printf '%s\n' "$output" | grep "hello linux-clean"
echo "linux x64 remote ok"
EOF

for remote_path in "$DEBIAN_ROOT" "$MATRIX_WORK_ROOT" "$MATRIX_SOURCE_CACHE" \
    "$MATRIX_EVIDENCE_ROOT"; do
    check_remote_tmp_path "$LINUX_DEBIAN" "$LINUX_DEBIAN_PORT" "$remote_path"
done
copy_tree_ssh "$LINUX_DEBIAN" "$LINUX_DEBIAN_PORT" "$DEBIAN_ROOT"
# shellcheck disable=SC2029 # Every expanded value is validated and shell-quoted locally.
ssh -p "$LINUX_DEBIAN_PORT" "$LINUX_DEBIAN" \
    "REMOTE_ROOT=$(quote_remote "$DEBIAN_ROOT") MATRIX_WORK_ROOT=$(quote_remote "$MATRIX_WORK_ROOT") MATRIX_SOURCE_CACHE=$(quote_remote "$MATRIX_SOURCE_CACHE") MATRIX_EVIDENCE_ROOT=$(quote_remote "$MATRIX_EVIDENCE_ROOT") sh -s" <<'EOF'
set -eu
command -v renice >/dev/null 2>&1 && renice 15 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1 || true
cd "$REMOTE_ROOT"
LUAI_MATRIX_EDGE_COVERAGE_MODE=available \
    HOST_LABEL=debian-x86_64 WORK_ROOT="$MATRIX_WORK_ROOT" \
    SOURCE_CACHE="$MATRIX_SOURCE_CACHE" EVIDENCE_DIR="$MATRIX_EVIDENCE_ROOT" \
    sh tools/test-lua-versions.sh
echo "debian x64 remote ok"
EOF

for remote_path in "$REMOTE_ROOT" "$MATRIX_WORK_ROOT" "$MATRIX_SOURCE_CACHE" \
    "$MATRIX_EVIDENCE_ROOT"; do
    check_remote_tmp_path "$LINUX_ARM64" "" "$remote_path"
done
copy_tree_default_ssh "$LINUX_ARM64" "$REMOTE_ROOT"

# shellcheck disable=SC2029 # Every expanded value is validated and shell-quoted locally.
ssh "$LINUX_ARM64" \
    "REMOTE_ROOT=$(quote_remote "$REMOTE_ROOT") MATRIX_WORK_ROOT=$(quote_remote "$MATRIX_WORK_ROOT") MATRIX_SOURCE_CACHE=$(quote_remote "$MATRIX_SOURCE_CACHE") MATRIX_EVIDENCE_ROOT=$(quote_remote "$MATRIX_EVIDENCE_ROOT") sh -s" <<'EOF'
set -eu
command -v renice >/dev/null 2>&1 && renice 15 -p $$ >/dev/null 2>&1 || true
command -v ionice >/dev/null 2>&1 && ionice -c 3 -p $$ >/dev/null 2>&1 || true
TEST_ROOT=/tmp/luainstaller-linux-arm64-run-$$
EMPTY_PATH=$TEST_ROOT/empty-path
INSTALL_ROOT=$TEST_ROOT/install
RUNTIME_ROOT=$TEST_ROOT/runtime
ONEFILE=$TEST_ROOT/runtime-onefile
CACHE_ROOT=$TEST_ROOT/cache
LINK_PATH=$TEST_ROOT/runtime-link
PIDS=

cleanup_test_artifacts() {
    for pid in $PIDS; do
        kill "$pid" >/dev/null 2>&1 || true
    done
    for pid in $PIDS; do
        wait "$pid" >/dev/null 2>&1 || true
    done
    rm -rf "$TEST_ROOT"
}
case "$TEST_ROOT" in /tmp/luainstaller-linux-arm64-run-[0-9]*) ;; *) exit 2 ;; esac
test ! -e "$TEST_ROOT" && test ! -L "$TEST_ROOT"
mkdir -m 700 "$TEST_ROOT"
mkdir -m 700 "$EMPTY_PATH"
trap cleanup_test_artifacts EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$REMOTE_ROOT"
LUAI_MATRIX_EDGE_COVERAGE_MODE=available \
    HOST_LABEL=dgx-spark-arm64 WORK_ROOT="$MATRIX_WORK_ROOT" \
    SOURCE_CACHE="$MATRIX_SOURCE_CACHE" EVIDENCE_DIR="$MATRIX_EVIDENCE_ROOT" \
    sh tools/test-lua-versions.sh

LUA_PREFIX=$MATRIX_WORK_ROOT/lua-5.4.8
LUAROCKS_PREFIX=$MATRIX_WORK_ROOT/luarocks-5.4.8
NATIVE_DEPS=$MATRIX_WORK_ROOT/native-deps-5.4.8
TEST_LUA=$LUA_PREFIX/bin/lua
TEST_LUAC=$LUA_PREFIX/bin/luac
TEST_LUAROCKS=$LUAROCKS_PREFIX/bin/luarocks
DEPS_LUA_PATH=$NATIVE_DEPS/share/lua/5.4/?.lua\;$NATIVE_DEPS/share/lua/5.4/?/init.lua
DEPS_LUA_CPATH=$NATIVE_DEPS/lib/lua/5.4/?.so\;$NATIVE_DEPS/lib/lua/5.4/?/init.so
test "$($TEST_LUA -e 'io.write(_VERSION)')" = "Lua 5.4"
test "$(PKG_CONFIG_PATH="$LUA_PREFIX/lib/pkgconfig" pkg-config --modversion lua)" = "5.4.8"
find src test tools -type f -name '*.lua' -print | while IFS= read -r file; do
    "$TEST_LUAC" -p "$file"
done

PATH=$LUAROCKS_PREFIX/bin:$LUA_PREFIX/bin:/usr/bin:/bin
LUA_PATH=$DEPS_LUA_PATH
LUA_CPATH=$DEPS_LUA_CPATH
LUAI_TEST_LUA=$TEST_LUA
LUAI_TEST_LUAC=$TEST_LUAC
LUAI_LUA_PREFIX=$LUA_PREFIX
LUAI_LUA_RELEASE=5.4.8
PKG_CONFIG_PATH=$LUA_PREFIX/lib/pkgconfig
export PATH LUA_PATH LUA_CPATH LUAI_TEST_LUA LUAI_TEST_LUAC
export LUAI_LUA_PREFIX LUAI_LUA_RELEASE PKG_CONFIG_PATH

"$TEST_LUA" -e 'require("cjson"); require("lfs"); require("socket.core"); require("mimetypes"); require("zlib"); require("pegasus"); require("lsqlite3")'
"$TEST_LUAROCKS" make --force --deps-mode=none --tree "$INSTALL_ROOT" \
    luainstaller-1.0.0-1.rockspec
"$INSTALL_ROOT/bin/luai" -v
"$INSTALL_ROOT/bin/luai" -a test/runtime_bundle/main.lua --max-deps 120

"$INSTALL_ROOT/bin/luainstaller" build --dir test/runtime_bundle/main.lua \
    -o "$RUNTIME_ROOT" --max-deps 120
output=$(env -i PATH="$EMPTY_PATH" "$RUNTIME_ROOT/$(basename "$RUNTIME_ROOT")" arm64-clean)
printf '%s\n' "$output" | grep "hello arm64-clean"

ln -s "$RUNTIME_ROOT/$(basename "$RUNTIME_ROOT")" "$LINK_PATH"
output=$(env -i PATH="$EMPTY_PATH" "$LINK_PATH" arm64-symlink)
printf '%s\n' "$output" | grep "hello arm64-symlink"

"$INSTALL_ROOT/bin/luainstaller" build --file test/runtime_bundle/main.lua \
    -o "$ONEFILE" --max-deps 120
mkdir -m 700 "$CACHE_ROOT"
output=$(env -i PATH="$EMPTY_PATH" TMPDIR="$CACHE_ROOT" "$ONEFILE" arm64-onefile)
printf '%s\n' "$output" | grep "hello arm64-onefile"

i=1
while [ "$i" -le 12 ]; do
    env -i PATH="$EMPTY_PATH" TMPDIR="$CACHE_ROOT" "$ONEFILE" \
        "arm64-concurrent-$i" >"$TEST_ROOT/concurrent-$i.log" 2>&1 &
    PIDS="$PIDS $!"
    i=$((i + 1))
done
for pid in $PIDS; do
    wait "$pid"
done
PIDS=
i=1
while [ "$i" -le 12 ]; do
    grep "hello arm64-concurrent-$i" "$TEST_ROOT/concurrent-$i.log"
    i=$((i + 1))
done

manifest=$(find "$CACHE_ROOT" -path '*/.luai/manifest.lua' -print -quit)
inner=$(find "$CACHE_ROOT" -type f -name inner -perm /111 -print -quit)
test -n "$manifest"
test -n "$inner"
chmod -x "$inner"
output=$(env -i PATH="$EMPTY_PATH" TMPDIR="$CACHE_ROOT" "$ONEFILE" arm64-mode-repair)
printf '%s\n' "$output" | grep "hello arm64-mode-repair"
test -x "$inner"
echo "linux arm64 remote ok"
EOF
