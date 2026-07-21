#!/bin/sh
set -eu

BASTION=${BASTION:-"waterrun@192.168.10.40"}
BASTION_PORT=${BASTION_PORT:-"22222"}
MAC_HOST=${MAC_HOST:-"yymac06"}
REMOTE_ROOT=${REMOTE_ROOT:-"/tmp/luainstaller-mac-current"}
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

remote_sh() {
    remote_command=$1
    mac_host=$(quote_remote "$MAC_HOST")
    quoted_command=$(quote_remote "$remote_command")
    ssh -p "$BASTION_PORT" "$BASTION" "ssh $mac_host $quoted_command"
}

check_remote_macos_tmp_path() {
    checked_path=$1
    remote_command="CHECK_PATH=$(quote_remote "$checked_path") sh -s"
    remote_sh "$remote_command" <<'EOF'
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
}

create_tracked_tree_archive() {
    TRACKED_ARCHIVE=$SOURCE_CACHE/tracked-tree.$$.tar
    rm -f "$TRACKED_ARCHIVE"
    (cd "$PROJECT_ROOT" && git -c tar.umask=0022 archive --format=tar HEAD) \
        >"$TRACKED_ARCHIVE"
}

copy_tree_macos() {
    remote_root=$(quote_remote "$REMOTE_ROOT")
    remote_command="rm -rf $remote_root && mkdir -m 700 -p $remote_root && tar -xpf - -C $remote_root"
    remote_sh "$remote_command" <"$TRACKED_ARCHIVE"
}

cleanup_local() {
    if [ -n "$TRACKED_ARCHIVE" ]; then
        rm -f "$TRACKED_ARCHIVE"
    fi
}

for safe_path in "$REMOTE_ROOT" "$SOURCE_CACHE" "$MATRIX_WORK_ROOT" \
    "$MATRIX_SOURCE_CACHE" "$MATRIX_EVIDENCE_ROOT"; do
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

for remote_path in "$REMOTE_ROOT" "$MATRIX_WORK_ROOT" "$MATRIX_SOURCE_CACHE" \
    "$MATRIX_EVIDENCE_ROOT"; do
    check_remote_macos_tmp_path "$remote_path"
done
create_tracked_tree_archive
copy_tree_macos

remote_command="REMOTE_ROOT=$(quote_remote "$REMOTE_ROOT") MATRIX_WORK_ROOT=$(quote_remote "$MATRIX_WORK_ROOT") MATRIX_SOURCE_CACHE=$(quote_remote "$MATRIX_SOURCE_CACHE") MATRIX_EVIDENCE_ROOT=$(quote_remote "$MATRIX_EVIDENCE_ROOT") sh -s"
remote_sh "$remote_command" <<'EOF'
set -eu
command -v renice >/dev/null 2>&1 && renice 15 -p $$ >/dev/null 2>&1 || true
TEST_ROOT=/tmp/luainstaller-macos-run-$$
EMPTY_PATH=$TEST_ROOT/empty-path
INSTALL_ROOT=$TEST_ROOT/install
RUNTIME_ROOT=$TEST_ROOT/runtime
RUNTIME_LINK=$TEST_ROOT/runtime-link
STUDENT_ROOT=$TEST_ROOT/student
ONEFILE_RUNTIME=$TEST_ROOT/runtime-onefile
ONEFILE_STUDENT=$TEST_ROOT/student-onefile
ONEFILE_CACHE=$TEST_ROOT/onefile-cache
SAVINGLUA_ROOT=$TEST_ROOT/savinglua
LTOKEI_ROOT=$TEST_ROOT/ltokei
FIREBIRD_ROOT=$TEST_ROOT/firebird
PIDS=
SERVER_PID=

cleanup_test_artifacts() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
    fi
    for pid in $PIDS; do
        kill "$pid" >/dev/null 2>&1 || true
    done
    for pid in $PIDS; do
        wait "$pid" >/dev/null 2>&1 || true
    done
    rm -rf "$TEST_ROOT"
}
case "$TEST_ROOT" in /tmp/luainstaller-macos-run-[0-9]*) ;; *) exit 2 ;; esac
test ! -e "$TEST_ROOT" && test ! -L "$TEST_ROOT"
mkdir -m 700 "$TEST_ROOT"
mkdir -m 700 "$EMPTY_PATH" "$ONEFILE_CACHE"
trap cleanup_test_artifacts EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

cd "$REMOTE_ROOT"
HOST_LABEL=macos-arm64 WORK_ROOT="$MATRIX_WORK_ROOT" \
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
LUA_PC_VERSION=$(awk '/^Version:/ {
    value = $0
    sub(/^Version:[[:space:]]*/, "", value)
    print value
    exit
}' "$LUA_PREFIX/lib/pkgconfig/lua.pc")
test "$LUA_PC_VERSION" = "5.4.8"
find src test tools -type f -name '*.lua' -exec "$TEST_LUAC" -p {} \;

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

bundle() {
    entry=$1
    output_root=$2
    "$INSTALL_ROOT/bin/luainstaller" build --dir "$entry" -o "$output_root" \
        --max-deps 250
}

bundle_onefile() {
    entry=$1
    output_file=$2
    "$INSTALL_ROOT/bin/luainstaller" build --file "$entry" -o "$output_file" \
        --max-deps 250
}

bundle_executable() {
    output_root=$1
    printf '%s/%s' "$output_root" "$(basename "$output_root")"
}

bundle test/runtime_bundle/main.lua "$RUNTIME_ROOT"
output=$(env -i PATH="$EMPTY_PATH" "$(bundle_executable "$RUNTIME_ROOT")" macos-clean)
printf '%s\n' "$output" | grep "hello macos-clean"
ln -s "$(bundle_executable "$RUNTIME_ROOT")" "$RUNTIME_LINK"
output=$(env -i PATH="$EMPTY_PATH" "$RUNTIME_LINK" macos-symlink)
printf '%s\n' "$output" | grep "hello macos-symlink"

STUDENT_DATA=$TEST_ROOT/students.json
bundle test/student_management_system/main.lua "$STUDENT_ROOT"
output=$(env -i PATH="$EMPTY_PATH" "$(bundle_executable "$STUDENT_ROOT")" \
    --data "$STUDENT_DATA" seed)
printf '%s\n' "$output" | grep "Seeded 8 students"
output=$(env -i PATH="$EMPTY_PATH" "$(bundle_executable "$STUDENT_ROOT")" \
    --data "$STUDENT_DATA" list --sort average)
printf '%s\n' "$output" | grep "Ada Lovelace"

bundle_onefile test/runtime_bundle/main.lua "$ONEFILE_RUNTIME"
first_hash=$(shasum -a 256 "$ONEFILE_RUNTIME" | awk '{ print $1 }')
rm -f "$ONEFILE_RUNTIME"
bundle_onefile test/runtime_bundle/main.lua "$ONEFILE_RUNTIME"
second_hash=$(shasum -a 256 "$ONEFILE_RUNTIME" | awk '{ print $1 }')
test "$first_hash" = "$second_hash"
output=$(env -i PATH="$EMPTY_PATH" TMPDIR="$ONEFILE_CACHE" \
    "$ONEFILE_RUNTIME" macos-onefile)
printf '%s\n' "$output" | grep "hello macos-onefile"

i=1
while [ "$i" -le 6 ]; do
    env -i PATH="$EMPTY_PATH" TMPDIR="$ONEFILE_CACHE" "$ONEFILE_RUNTIME" \
        "macos-concurrent-$i" >"$TEST_ROOT/concurrent-$i.log" 2>&1 &
    PIDS="$PIDS $!"
    i=$((i + 1))
done
for pid in $PIDS; do
    wait "$pid"
done
PIDS=
i=1
while [ "$i" -le 6 ]; do
    grep "hello macos-concurrent-$i" "$TEST_ROOT/concurrent-$i.log"
    i=$((i + 1))
done

ONEFILE_STUDENT_DATA=$TEST_ROOT/onefile-students.json
bundle_onefile test/student_management_system/main.lua "$ONEFILE_STUDENT"
output=$(env -i PATH="$EMPTY_PATH" TMPDIR="$ONEFILE_CACHE" "$ONEFILE_STUDENT" \
    --data "$ONEFILE_STUDENT_DATA" seed)
printf '%s\n' "$output" | grep "Seeded 8 students"
output=$(env -i PATH="$EMPTY_PATH" TMPDIR="$ONEFILE_CACHE" "$ONEFILE_STUDENT" \
    --data "$ONEFILE_STUDENT_DATA" list --sort average)
printf '%s\n' "$output" | grep "Ada Lovelace"

SAVINGLUA_DB=$TEST_ROOT/savinglua.sqlite3
bundle test/savinglua/main.lua "$SAVINGLUA_ROOT"
output=$(env -i PATH="$EMPTY_PATH" "$(bundle_executable "$SAVINGLUA_ROOT")" \
    --db "$SAVINGLUA_DB" put users:ada '{"name":"Ada Lovelace","score":98}')
printf '%s\n' "$output" | grep "stored users:ada"
output=$(env -i PATH="$EMPTY_PATH" "$(bundle_executable "$SAVINGLUA_ROOT")" \
    --db "$SAVINGLUA_DB" get users:ada)
printf '%s\n' "$output" | grep "Ada Lovelace"

bundle test/ltokei/main.lua "$LTOKEI_ROOT"
output=$(env -i PATH="$EMPTY_PATH" "$(bundle_executable "$LTOKEI_ROOT")" \
    "$LTOKEI_ROOT/.luai")
printf '%s\n' "$output" | grep "Total"

bundle test/firebird_web_sql/server.lua "$FIREBIRD_ROOT"
attempt=1
server_ready=false
while [ "$attempt" -le 5 ]; do
    PORT=$((20000 + ($$ + attempt * 997) % 30000))
    : >"$TEST_ROOT/firebird.log"
    env -i PATH="$EMPTY_PATH" FIREBIRD_WEB_SQL_PORT="$PORT" \
        FIREBIRD_WEB_SQL_TOKEN=testtoken "$(bundle_executable "$FIREBIRD_ROOT")" \
        >"$TEST_ROOT/firebird.log" 2>&1 &
    SERVER_PID=$!
    poll=1
    while [ "$poll" -le 40 ]; do
        if ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
            wait "$SERVER_PID" >/dev/null 2>&1 || true
            SERVER_PID=
            break
        fi
        response=$(curl -fsS "http://127.0.0.1:$PORT/api/status" \
            -H "X-Auth-Token: testtoken" 2>/dev/null || true)
        if printf '%s\n' "$response" | grep '"ok":true' >/dev/null; then
            server_ready=true
            break
        fi
        sleep 0.25
        poll=$((poll + 1))
    done
    if [ "$server_ready" = true ]; then
        break
    fi
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
        SERVER_PID=
    fi
    attempt=$((attempt + 1))
done
if [ "$server_ready" != true ]; then
    cat "$TEST_ROOT/firebird.log" >&2
    exit 1
fi
kill "$SERVER_PID" >/dev/null 2>&1 || true
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=
echo "macOS arm64 remote ok"
EOF
