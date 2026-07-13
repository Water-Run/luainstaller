#!/bin/sh
set -eu

# Lab defaults match /home/waterrun/VM/SSH_Win10_README.md / SSH_Win7_README.md (Win10 OpenSSH, Win7 KTS).
WINDOWS_HOST=${WINDOWS_HOST:-"waterrun@192.168.69.130"}
WINDOWS_TARGETS=${WINDOWS_TARGETS:-"Win10=$WINDOWS_HOST"}
SSH_PORT=${SSH_PORT:-22}
SSH_IDENTITY_FILE=${SSH_IDENTITY_FILE:-""}
REMOTE_TEMP=${REMOTE_TEMP:-"C:/Users/waterrun/AppData/Local/Temp"}
SOURCE_CACHE=${SOURCE_CACHE:-"/tmp/luainstaller-source-cache"}
WIN_PREFIX=${WIN_PREFIX:-"/tmp/luainstaller-win-lua"}
WIN_TREE=${WIN_TREE:-"/tmp/luainstaller-win-rocks"}
WIN_OUT=${WIN_OUT:-"/tmp/luainstaller-win-bundles"}
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

LUA_VERSION=5.4.8
LUA_TARBALL=lua-$LUA_VERSION.tar.gz
LSQLITE3_ZIP=lsqlite3_v096.zip
SQLITE_ZIP=sqlite-amalgamation-3530200.zip
LUA_SHA256=4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
LSQLITE3_SHA256=ecc6e7636a54f021bca5b4a01b35af06fd7a6fc8b21c4b3eccd4fdb5dd32ad82
SQLITE_SHA256=8a310d0a16c7a90cacd4c884e70faa51c902afed2a89f63aaa0126ab83558a32

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
        if [ ! -e "$current" ]; then
            break
        fi
    done
}

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
    require_no_symlink_ancestors "$path"
}

require_safe_windows_temp() {
    case "$1" in
        [A-Za-z]:/*) ;;
        *)
            echo "unsafe Windows temporary path: $1" >&2
            exit 2
            ;;
    esac
    case "$1" in
        *[!A-Za-z0-9._:/-]*)
            echo "unsafe characters in Windows temporary path: $1" >&2
            exit 2
            ;;
    esac
    case "$1" in
        *'/../'*|*'/..'|*'/./'*|*'/.'|*'//'*)
            echo "non-normalized Windows temporary path: $1" >&2
            exit 2
            ;;
    esac
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

validate_remote_configuration() {
    if [ -n "${SSH_OPTS:-}" ] || [ -n "${SSH_KEY_OPTS:-}" ]; then
        echo "SSH_OPTS must not override host-key policy" >&2
        exit 2
    fi
    case "$SSH_PORT" in
        ''|*[!0-9]*)
            echo "SSH_PORT must be an integer from 1 through 65535" >&2
            exit 2
            ;;
    esac
    if [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
        echo "SSH_PORT must be an integer from 1 through 65535" >&2
        exit 2
    fi
    if [ -n "$SSH_IDENTITY_FILE" ]; then
        case "$SSH_IDENTITY_FILE" in
            -*)
                echo "SSH_IDENTITY_FILE must be a regular file path" >&2
                exit 2
                ;;
        esac
        if [ ! -f "$SSH_IDENTITY_FILE" ] || [ -L "$SSH_IDENTITY_FILE" ]; then
            echo "SSH_IDENTITY_FILE must be a non-symlink regular file" >&2
            exit 2
        fi
    fi
    if [ -z "$WINDOWS_TARGETS" ]; then
        echo "WINDOWS_TARGETS must name at least one required lab" >&2
        exit 2
    fi
    need_cmd base64
    need_cmd iconv
    need_cmd scp
    need_cmd ssh
    if [ -n "${WINDOWS_PASSWORD:-}" ]; then
        need_cmd sshpass
    fi
}

if [ "${WINDOWS_LOCAL_ONLY:-0}" != 1 ]; then
    validate_remote_configuration
fi

strict_scp() {
    if [ -n "${WINDOWS_PASSWORD:-}" ]; then
        if [ -n "$SSH_IDENTITY_FILE" ]; then
            SSHPASS=$WINDOWS_PASSWORD sshpass -e scp -o StrictHostKeyChecking=yes \
                -P "$SSH_PORT" -i "$SSH_IDENTITY_FILE" "$@"
        else
            SSHPASS=$WINDOWS_PASSWORD sshpass -e scp -o StrictHostKeyChecking=yes \
                -P "$SSH_PORT" "$@"
        fi
    elif [ -n "$SSH_IDENTITY_FILE" ]; then
        scp -o StrictHostKeyChecking=yes -o BatchMode=yes \
            -P "$SSH_PORT" -i "$SSH_IDENTITY_FILE" "$@"
    else
        scp -o StrictHostKeyChecking=yes -o BatchMode=yes -P "$SSH_PORT" "$@"
    fi
}

strict_ssh() {
    if [ -n "${WINDOWS_PASSWORD:-}" ]; then
        if [ -n "$SSH_IDENTITY_FILE" ]; then
            SSHPASS=$WINDOWS_PASSWORD sshpass -e ssh -o StrictHostKeyChecking=yes \
                -p "$SSH_PORT" -i "$SSH_IDENTITY_FILE" "$@"
        else
            SSHPASS=$WINDOWS_PASSWORD sshpass -e ssh -o StrictHostKeyChecking=yes \
                -p "$SSH_PORT" "$@"
        fi
    elif [ -n "$SSH_IDENTITY_FILE" ]; then
        ssh -o StrictHostKeyChecking=yes -o BatchMode=yes \
            -p "$SSH_PORT" -i "$SSH_IDENTITY_FILE" "$@"
    else
        ssh -o StrictHostKeyChecking=yes -o BatchMode=yes -p "$SSH_PORT" "$@"
    fi
}

preflight_windows_upload() {
    preflight_host=$1
    preflight_script=$(cat <<'PS1'
$ErrorActionPreference = 'Stop'
$StagingRoot = '__LUAI_STAGING_ROOT__'
if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
    throw 'Windows upload staging root is required'
}
$StagingRoot = [IO.Path]::GetFullPath($StagingRoot)
$driveRoot = [IO.Path]::GetPathRoot($StagingRoot)
if ([string]::IsNullOrEmpty($driveRoot)) {
    throw 'Windows upload staging root must be absolute'
}
$current = $driveRoot
$paths = @($current)
$relativeComponents = $StagingRoot.Substring($driveRoot.Length) -split '[\\/]'
foreach ($component in $relativeComponents) {
    if ($component -eq '') { continue }
    $current = Join-Path $current $component
    $paths += $current
}
foreach ($path in $paths) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if (-not ($item -is [IO.DirectoryInfo]) -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "unsafe Windows upload-path ancestor: $path"
    }
}
foreach ($name in @('luainstaller-win-bundles.tar.gz',
        'luainstaller-run-windows-bundles.ps1')) {
    $target = Join-Path $StagingRoot $name
    $targetItem = Get-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
    if ($null -eq $targetItem) { continue }
    if (-not ($targetItem -is [IO.FileInfo]) -or
        ($targetItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "unsafe Windows upload target: $target"
    }
    [IO.File]::Delete($target)
    if (Test-Path -LiteralPath $target) {
        throw "failed to clear Windows upload target: $target"
    }
}
PS1
)
    preflight_script=$(printf '%s' "$preflight_script" \
        | sed "s|__LUAI_STAGING_ROOT__|$REMOTE_TEMP|")
    preflight_encoded=$(printf '%s' "$preflight_script" \
        | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\r\n')
    if [ -z "$preflight_encoded" ]; then
        echo "failed to encode Windows upload preflight" >&2
        exit 1
    fi
    strict_ssh "$preflight_host" \
        "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand \"$preflight_encoded\""
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

ensure_windows_lua() {
    if [ -x "$WIN_PREFIX/lua.exe" ] && [ -f "$WIN_PREFIX/bin/lua54.dll" ] && [ -f "$WIN_PREFIX/include/lua.h" ]; then
        if WINEDEBUG=-all wine "$WIN_PREFIX/lua.exe" -v 2>&1 | grep 'Lua 5\.4\.8' >/dev/null; then
            return
        fi
    fi
    rm -rf "$WIN_PREFIX" /tmp/luainstaller-win-lua-build
    mkdir -p "$WIN_PREFIX/bin" "$WIN_PREFIX/include" /tmp/luainstaller-win-lua-build
    tar -xzf "$SOURCE_CACHE/$LUA_TARBALL" -C /tmp/luainstaller-win-lua-build
    (
        cd "/tmp/luainstaller-win-lua-build/lua-$LUA_VERSION"
        make clean >/tmp/luainstaller-windows-lua-clean.log 2>&1 || true
        make mingw \
            CC=x86_64-w64-mingw32-gcc \
            AR='x86_64-w64-mingw32-ar rcu' \
            RANLIB=x86_64-w64-mingw32-ranlib \
            >/tmp/luainstaller-windows-lua-build.log 2>&1
        cp src/lua.exe src/lua54.dll "$WIN_PREFIX/"
        cp src/lua54.dll "$WIN_PREFIX/bin/"
        cp src/lua.h src/luaconf.h src/lualib.h src/lauxlib.h src/lua.hpp "$WIN_PREFIX/include/"
    )
}

unpack_rock() {
    name=$1
    version=$2
    out_dir=$3
    if [ ! -d "$out_dir" ]; then
        luarocks unpack "$name" "$version" >/tmp/luainstaller-windows-unpack-"$name".log
    fi
}

build_windows_deps() {
    rm -rf "$WIN_TREE" /tmp/luainstaller-win-deps-src /tmp/luainstaller-win-lsqlite-build
    mkdir -p "$WIN_TREE/lib/lua/5.4/socket" "$WIN_TREE/lib/lua/5.4/mime"
    mkdir -p "$WIN_TREE/share/lua/5.4/socket" "$WIN_TREE/share/lua/5.4/mime"
    mkdir -p /tmp/luainstaller-win-deps-src

    (
        cd /tmp/luainstaller-win-deps-src
        unpack_rock lua-cjson 2.1.0.10-1 lua-cjson-2.1.0.10-1
        unpack_rock luafilesystem 1.9.0-1 luafilesystem-1.9.0-1
        unpack_rock luasocket 3.1.0-1 luasocket-3.1.0-1
        unpack_rock pegasus 1.1.0-0 pegasus-1.1.0-0
        unpack_rock mimetypes 1.1.0-2 mimetypes-1.1.0-2
    )

    cc=x86_64-w64-mingw32-gcc
    cjson=/tmp/luainstaller-win-deps-src/lua-cjson-2.1.0.10-1/lua-cjson
    lfs=/tmp/luainstaller-win-deps-src/luafilesystem-1.9.0-1/luafilesystem
    luasocket=/tmp/luainstaller-win-deps-src/luasocket-3.1.0-1/luasocket
    pegasus=/tmp/luainstaller-win-deps-src/pegasus-1.1.0-0/pegasus.lua/src
    mimetypes=/tmp/luainstaller-win-deps-src/mimetypes-1.1.0-2/lua-mimetypes

    "$cc" -O2 -shared -I"$WIN_PREFIX/include" -I"$cjson" \
        "$cjson/lua_cjson.c" "$cjson/strbuf.c" "$cjson/fpconv.c" \
        -L"$WIN_PREFIX/bin" -llua54 \
        -o "$WIN_TREE/lib/lua/5.4/cjson.dll" \
        -Wl,--export-all-symbols -static-libgcc

    "$cc" -O2 -shared -I"$WIN_PREFIX/include" -I"$lfs/src" \
        "$lfs/src/lfs.c" \
        -L"$WIN_PREFIX/bin" -llua54 \
        -o "$WIN_TREE/lib/lua/5.4/lfs.dll" \
        -Wl,--export-all-symbols -static-libgcc

    mkdir -p /tmp/luainstaller-win-lsqlite-build
    (
        cd /tmp/luainstaller-win-lsqlite-build
        unzip -q "$SOURCE_CACHE/$LSQLITE3_ZIP" -d lsqlite3-src
        unzip -q "$SOURCE_CACHE/$SQLITE_ZIP"
        lsqlite_dir=$(find lsqlite3-src -name lsqlite3.c -exec dirname {} \; 2>/dev/null | head -n 1)
        sqlite_dir=$(find . -name sqlite3.c -exec dirname {} \; 2>/dev/null | head -n 1)
        "$cc" -O2 -shared -I"$WIN_PREFIX/include" -I"$sqlite_dir" \
            -DLSQLITE_VERSION=\"0.9.6\" \
            "$lsqlite_dir/lsqlite3.c" "$sqlite_dir/sqlite3.c" \
            -L"$WIN_PREFIX/bin" -llua54 \
            -o "$WIN_TREE/lib/lua/5.4/lsqlite3.dll" \
            -Wl,--export-all-symbols -static-libgcc
    )

    "$cc" -O2 -shared -I"$WIN_PREFIX/include" -I"$luasocket/src" \
        -DLUASOCKET_DEBUG -DWINVER=0x0501 \
        "$luasocket/src/luasocket.c" "$luasocket/src/timeout.c" \
        "$luasocket/src/buffer.c" "$luasocket/src/io.c" \
        "$luasocket/src/auxiliar.c" "$luasocket/src/options.c" \
        "$luasocket/src/inet.c" "$luasocket/src/except.c" \
        "$luasocket/src/select.c" "$luasocket/src/tcp.c" \
        "$luasocket/src/udp.c" "$luasocket/src/compat.c" \
        "$luasocket/src/wsocket.c" \
        -L"$WIN_PREFIX/bin" -llua54 -lws2_32 \
        -o "$WIN_TREE/lib/lua/5.4/socket/core.dll" \
        -Wl,--export-all-symbols -static-libgcc

    "$cc" -O2 -shared -I"$WIN_PREFIX/include" -I"$luasocket/src" \
        -DLUASOCKET_DEBUG -DWINVER=0x0501 \
        "$luasocket/src/mime.c" "$luasocket/src/compat.c" \
        -L"$WIN_PREFIX/bin" -llua54 \
        -o "$WIN_TREE/lib/lua/5.4/mime/core.dll" \
        -Wl,--export-all-symbols -static-libgcc

    cp "$luasocket/src/socket.lua" "$WIN_TREE/share/lua/5.4/socket.lua"
    cp "$luasocket/src/mime.lua" "$WIN_TREE/share/lua/5.4/mime.lua"
    for f in http url tp ftp headers smtp; do
        cp "$luasocket/src/$f.lua" "$WIN_TREE/share/lua/5.4/socket/$f.lua"
    done
    cp "$luasocket/src/ltn12.lua" "$WIN_TREE/share/lua/5.4/ltn12.lua"
    cp -R "$pegasus/pegasus" "$WIN_TREE/share/lua/5.4/"
    cp "$mimetypes/mimetypes.lua" "$WIN_TREE/share/lua/5.4/"
    mkdir -p "$WIN_TREE/share/lua/5.4/mimetypes"
    cp "$mimetypes/mimetypes/"*.lua "$WIN_TREE/share/lua/5.4/mimetypes/"

    cp "$WIN_PREFIX/lua.exe" "$WIN_TREE/"
    cp "$WIN_PREFIX/bin/lua54.dll" "$WIN_TREE/"
    (
        cd "$WIN_TREE"
        wine ./lua.exe -e 'package.path="share/lua/5.4/?.lua;share/lua/5.4/?/init.lua;"; package.cpath="lib/lua/5.4/?.dll;lib/lua/5.4/?/core.dll;"; require("cjson"); require("lfs"); require("lsqlite3"); require("socket.core"); require("pegasus"); print("windows deps ok")'
    )
}

bundle_demo() {
    entry=$1
    out=$2
    lua_path="$PROJECT_ROOT/src/?.lua;$PROJECT_ROOT/src/?/init.lua;$WIN_TREE/share/lua/5.4/?.lua;$WIN_TREE/share/lua/5.4/?/init.lua;;"
    lua_cpath="$WIN_TREE/lib/lua/5.4/?.dll;$WIN_TREE/lib/lua/5.4/?/core.dll;$WIN_TREE/lib/lua/5.4/?/init.dll;;"
    LUA_PATH="$lua_path" LUA_CPATH="$lua_cpath" \
        lua "$PROJECT_ROOT/src/cli.lua" -b --dir "$PROJECT_ROOT/$entry" \
        -o "$out" --target-os windows --lua-prefix "$WIN_PREFIX" --max-deps 300
}

bundle_demo_onefile() {
    entry=$1
    out=$2
    case "$entry" in
        /*) entry_path=$entry ;;
        *) entry_path=$PROJECT_ROOT/$entry ;;
    esac
    lua_path="$PROJECT_ROOT/src/?.lua;$PROJECT_ROOT/src/?/init.lua;$WIN_TREE/share/lua/5.4/?.lua;$WIN_TREE/share/lua/5.4/?/init.lua;;"
    lua_cpath="$WIN_TREE/lib/lua/5.4/?.dll;$WIN_TREE/lib/lua/5.4/?/core.dll;$WIN_TREE/lib/lua/5.4/?/init.dll;;"
    LUA_PATH="$lua_path" LUA_CPATH="$lua_cpath" \
        lua "$PROJECT_ROOT/src/cli.lua" -b --file "$entry_path" \
        -o "$out" --target-os windows --lua-prefix "$WIN_PREFIX" --max-deps 300
}

build_bundles() {
    rm -rf "$WIN_OUT"
    mkdir -p "$WIN_OUT"
    bundle_demo test/runtime_bundle/main.lua "$WIN_OUT/runtime"
    bundle_demo test/student_management_system/main.lua "$WIN_OUT/student"
    bundle_demo_onefile test/runtime_bundle/main.lua "$WIN_OUT/runtime-onefile"
    bundle_demo_onefile test/student_management_system/main.lua "$WIN_OUT/student-onefile"
    cat >/tmp/luainstaller-onefile-hold.lua <<'LUA'
local marker = assert(arg[1], "marker path is required")
local release = assert(arg[2], "release path is required")
local handle = assert(io.open(marker, "wb"))
assert(handle:write(tostring(arg[0])))
assert(handle:close())
local deadline = os.time() + 30
while os.time() <= deadline do
    local released = io.open(release, "rb")
    if released then
        assert(released:close())
        print("onefile pin probe released")
        return
    end
end
error("onefile pin probe timed out")
LUA
    bundle_demo_onefile /tmp/luainstaller-onefile-hold.lua "$WIN_OUT/pin-probe"
    bundle_demo test/savinglua/main.lua "$WIN_OUT/savinglua"
    bundle_demo test/ltokei/main.lua "$WIN_OUT/ltokei"
    bundle_demo test/firebird_web_sql/server.lua "$WIN_OUT/firebird"
    cat >/tmp/luainstaller-win-argv-driver.c <<'C'
#include <stdio.h>
#include <string.h>
#include <windows.h>

int main(int argc, char **argv) {
    char command[32768];
    STARTUPINFOA startup;
    PROCESS_INFORMATION process;
    DWORD exit_code = 1;
    const char *argument;
    if (argc != 3) return 2;
    if (strcmp(argv[2], "quote") == 0) {
        argument = "\"say \\\"hello\\\"\\tail\"";
    } else if (strcmp(argv[2], "trailing") == 0) {
        argument = "\"C:\\Alpha Beta\\trail\\\\\"";
    } else if (strcmp(argv[2], "empty") == 0) {
        argument = "\"\"";
    } else {
        return 2;
    }
    if (snprintf(command, sizeof(command), "\"%s\" %s", argv[1], argument) < 0) return 2;
    ZeroMemory(&startup, sizeof(startup));
    ZeroMemory(&process, sizeof(process));
    startup.cb = sizeof(startup);
    if (!CreateProcessA(NULL, command, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) return 3;
    WaitForSingleObject(process.hProcess, INFINITE);
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return (int)exit_code;
}
C
    x86_64-w64-mingw32-gcc /tmp/luainstaller-win-argv-driver.c \
        -o "$WIN_OUT/argv-driver.exe" -static-libgcc
    mkdir -p "$WIN_OUT/fs-probe/luainstaller"
    cp "$WIN_PREFIX/lua.exe" "$WIN_PREFIX/lua54.dll" "$WIN_OUT/fs-probe/"
    cp "$PROJECT_ROOT/src/fs.lua" "$PROJECT_ROOT/src/logger.lua" \
        "$PROJECT_ROOT/src/process.lua" \
        "$WIN_OUT/fs-probe/luainstaller/"
    cat >"$WIN_OUT/fs-probe/probe.lua" <<'LUA'
local fs = require("luainstaller.fs")
local logger = require("luainstaller.logger")
local regular, directory, reparse, root, non_ascii = ...
assert(fs.isRegularFile(regular), "empty regular file was rejected")
assert(fs.isRegularFile(non_ascii), "ACP-representable non-ASCII regular file was rejected")
assert(not fs.isRegularFile(directory), "directory was accepted as a regular file")
assert(not fs.isRegularFile(reparse), "reparse point was accepted as a regular file")
assert(not fs.isRegularFile("NUL"), "NUL device was accepted as a regular file")
assert(not fs.isRegularFile(root .. "\\NUL.lua"), "qualified NUL device was accepted")
assert(logger.clearLogs(), "logger clear failed with a clean Windows PATH")
assert(logger.logInfo("windows-probe", "clean-path", "ok"),
    "logger write failed with a clean Windows PATH")
local logs = logger.getLogs({ source = "windows-probe" })
assert(#logs == 1 and logs[1].message == "ok", "logger readback failed")
assert(logger.clearLogs(), "logger final clear failed")
print("windows filesystem and logger probe ok")
LUA
}

verify_with_wine() {
    rm -f /tmp/luainstaller-win-students.json /tmp/luainstaller-win-students-onefile.json /tmp/luainstaller-win-savinglua.sqlite3
    output=$(wine "$WIN_OUT/runtime/runtime.exe" wine-clean)
    printf '%s\n' "$output" | grep "hello wine-clean"
    output=$(wine "$WIN_OUT/student/student.exe" --data Z:/tmp/luainstaller-win-students.json seed)
    printf '%s\n' "$output" | grep "Seeded 8 students"
    output=$(wine "$WIN_OUT/student/student.exe" --data Z:/tmp/luainstaller-win-students.json list --sort average)
    printf '%s\n' "$output" | grep "Ada Lovelace"
    output=$(wine "$WIN_OUT/runtime-onefile.exe" wine-onefile-clean)
    printf '%s\n' "$output" | grep "hello wine-onefile-clean"
    windows_path='C:\Alpha Beta\trail'
    output=$(wine "$WIN_OUT/runtime-onefile.exe" "$windows_path")
    printf '%s\n' "$output" | grep -F "hello $windows_path"
    quoted_arg='say "hello"\tail'
    output=$(wine "$WIN_OUT/runtime-onefile.exe" "$quoted_arg")
    printf '%s\n' "$output" | grep -F "hello $quoted_arg"
    # shellcheck disable=SC1003 # The final backslash is literal inside single quotes.
    trailing_arg='C:\Alpha Beta\trail\'
    output=$(wine "$WIN_OUT/runtime-onefile.exe" "$trailing_arg")
    printf '%s\n' "$output" | grep -F "hello $trailing_arg"
    output=$(wine "$WIN_OUT/runtime-onefile.exe" "")
    printf '%s\n' "$output" | tr -d '\r' | grep -x 'hello '
    output=$(wine "$WIN_OUT/student-onefile.exe" --data Z:/tmp/luainstaller-win-students-onefile.json seed)
    printf '%s\n' "$output" | grep "Seeded 8 students"
    output=$(wine "$WIN_OUT/student-onefile.exe" --data Z:/tmp/luainstaller-win-students-onefile.json list --sort average)
    printf '%s\n' "$output" | grep "Ada Lovelace"
    output=$(wine "$WIN_OUT/savinglua/savinglua.exe" --db Z:/tmp/luainstaller-win-savinglua.sqlite3 put users:ada '{"name":"Ada Lovelace","score":98}')
    printf '%s\n' "$output" | grep "stored users:ada"
    output=$(wine "$WIN_OUT/savinglua/savinglua.exe" --db Z:/tmp/luainstaller-win-savinglua.sqlite3 get users:ada)
    printf '%s\n' "$output" | grep "Ada Lovelace"
    output=$(wine "$WIN_OUT/ltokei/ltokei.exe" Z:"$WIN_OUT/ltokei/.luai")
    printf '%s\n' "$output" | grep "Total"
    port=$((20000 + $$ % 20000))
    FIREBIRD_WEB_SQL_PORT=$port FIREBIRD_WEB_SQL_TOKEN=testtoken wine "$WIN_OUT/firebird/firebird.exe" >/tmp/luainstaller-windows-firebird.log 2>&1 &
    pid=$!
    for _ in $(seq 1 60); do
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            cat /tmp/luainstaller-windows-firebird.log
            exit 1
        fi
        response=$(curl -fsS "http://127.0.0.1:$port/api/status" -H "X-Auth-Token: testtoken" 2>/dev/null || true)
        if printf '%s\n' "$response" | grep '"ok":true' >/dev/null; then
            kill "$pid" >/dev/null 2>&1 || true
            wait "$pid" >/dev/null 2>&1 || true
            echo "windows wine firebird ok"
            return
        fi
        sleep 0.25
    done
    cat /tmp/luainstaller-windows-firebird.log
    exit 1
}

run_remote_windows() {
    runner=/tmp/luainstaller-run-windows-bundles.ps1
    archive=/tmp/luainstaller-win-bundles.tar.gz
    win_out_parent=$(dirname "$WIN_OUT")
    win_out_name=$(basename "$WIN_OUT")
    rm -f "$archive" "$runner"
    tar -C "$win_out_parent" -czf "$archive" -- "$win_out_name"
    cat >"$runner" <<'PS1'
param([string]$StagingRoot, [string]$BundleDirectoryName)
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($StagingRoot)) {
    throw 'Windows staging root is required'
}
if ([string]::IsNullOrWhiteSpace($BundleDirectoryName) -or
    $BundleDirectoryName -in @('.', '..') -or
    $BundleDirectoryName.IndexOfAny([char[]]'\/') -ge 0 -or
    $BundleDirectoryName.StartsWith('-') -or
    $BundleDirectoryName.EndsWith('.') -or
    $BundleDirectoryName -match '^(CON|PRN|AUX|NUL|CLOCK[$]|COM[1-9]|LPT[1-9])([.]|$)') {
    throw 'Windows bundle directory name is invalid'
}
$StagingRoot = [IO.Path]::GetFullPath($StagingRoot)
$driveRoot = [IO.Path]::GetPathRoot($StagingRoot)
$current = $driveRoot
$relativeComponents = $StagingRoot.Substring($driveRoot.Length) -split '[\\/]'
foreach ($component in $relativeComponents) {
    if ($component -eq '') { continue }
    $current = Join-Path $current $component
    $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not $item.PSIsContainer) {
        throw "unsafe Windows staging-path ancestor: $current"
    }
}
$root = Join-Path $StagingRoot $BundleDirectoryName
if (Test-Path $root) {
    $rootItem = Get-Item -LiteralPath $root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not $rootItem.PSIsContainer) {
        throw "unsafe Windows remote temporary root: $root"
    }
    Remove-Item -Recurse -Force -LiteralPath $root
}
tar -xzf (Join-Path $StagingRoot 'luainstaller-win-bundles.tar.gz') -C $StagingRoot
$env:Path = 'C:\Windows\System32;C:\Windows'
$env:LUA_PATH = $null
$env:LUA_CPATH = $null

function Require-Match($Text, $Pattern, $Name) {
    if ($Text -notmatch $Pattern) {
        throw "$Name did not match $Pattern. Output: $Text"
    }
}

function Invoke-NativeChecked($Name, [scriptblock]$Command) {
    $raw = & $Command 2>&1
    $code = $LASTEXITCODE
    $text = $raw | Out-String
    if ($code -ne 0) {
        throw "$Name exited with code $code. Output: $text"
    }
    return $text
}

$probeRoot = Join-Path $root 'fs-probe'
$probeRegular = Join-Path $probeRoot 'empty.lua'
$probeDirectory = Join-Path $probeRoot 'directory'
$probeTarget = Join-Path $probeRoot 'junction-target'
$probeReparse = Join-Path $probeRoot 'junction'
$probeHome = Join-Path $probeRoot 'home'
$probeSpecialHome = Join-Path $probeRoot 'home&A%caret^bang!'
$probeNonAscii = $null
foreach ($candidate in @([char]0x00E9, [char]0x6D4B, [char]0x0416, [char]0x3042)) {
    $candidateText = [string]$candidate
    $candidateBytes = [Text.Encoding]::Default.GetBytes($candidateText)
    if ([Text.Encoding]::Default.GetString($candidateBytes) -eq $candidateText -and
        -not ($candidateBytes.Length -eq 1 -and $candidateBytes[0] -eq 63)) {
        $probeNonAscii = Join-Path $probeRoot ("non-ascii-$candidateText.lua")
        break
    }
}
if ($null -eq $probeNonAscii) {
    throw 'active Windows ANSI code page has no representable non-ASCII probe candidate'
}
[IO.File]::WriteAllBytes($probeRegular, [byte[]]@())
[IO.File]::WriteAllBytes($probeNonAscii, [byte[]]@())
New-Item -ItemType Directory -Path $probeDirectory -Force | Out-Null
New-Item -ItemType Directory -Path $probeTarget -Force | Out-Null
New-Item -ItemType Junction -Path $probeReparse -Target $probeTarget | Out-Null
New-Item -ItemType Directory -Path $probeHome -Force | Out-Null
New-Item -ItemType Directory -Path $probeSpecialHome -Force | Out-Null
$env:LUA_PATH = "$probeRoot\?.lua;$probeRoot\?\init.lua;;"
$savedHome = $env:HOME
$env:HOME = $probeHome
$fileTypeProbe = Invoke-NativeChecked 'Windows filesystem and logger probe' {
    & (Join-Path $probeRoot 'lua.exe') (Join-Path $probeRoot 'probe.lua') $probeRegular $probeDirectory $probeReparse $probeRoot $probeNonAscii
}
$env:HOME = $probeSpecialHome
$specialHomeProbe = Invoke-NativeChecked 'Windows logger metacharacter HOME probe' {
    & (Join-Path $probeRoot 'lua.exe') (Join-Path $probeRoot 'probe.lua') $probeRegular $probeDirectory $probeReparse $probeRoot $probeNonAscii
}
$env:HOME = $savedHome
Require-Match $fileTypeProbe 'windows filesystem and logger probe ok' 'Windows filesystem and logger probe'
Require-Match $specialHomeProbe 'windows filesystem and logger probe ok' 'Windows logger metacharacter HOME probe'
$env:LUA_PATH = $null

$runtimeExe = Join-Path $root 'runtime\runtime.exe'
$runtime = Invoke-NativeChecked 'runtime' { & $runtimeExe 'windows-clean' }
Require-Match $runtime 'hello windows-clean' 'runtime'

$runtimeOnefileExe = Join-Path $root 'runtime-onefile.exe'
$onefileCache = Join-Path $env:TEMP 'luainstaller-onefile'
if (Test-Path $onefileCache) { Remove-Item -Recurse -Force $onefileCache }
$runtimeOnefile = Invoke-NativeChecked 'runtime onefile' { & $runtimeOnefileExe 'windows-onefile-clean' }
Require-Match $runtimeOnefile 'hello windows-onefile-clean' 'runtime onefile'
$cachedInner = Get-ChildItem $onefileCache -Recurse -File -Filter 'inner.exe' |
    Select-Object -First 1
if (-not $cachedInner) { throw 'runtime onefile cache inner.exe was not found' }
$looseAcl = Get-Acl $cachedInner.FullName
$everyone = New-Object System.Security.Principal.SecurityIdentifier('S-1-1-0')
$looseRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
    $everyone, 'FullControl', 'Allow')
$looseAcl.SetAccessRule($looseRule)
Set-Acl -Path $cachedInner.FullName -AclObject $looseAcl
$runtimeOnefileAcl = Invoke-NativeChecked 'runtime onefile ACL repair' { & $runtimeOnefileExe 'windows-acl-repair' }
Require-Match $runtimeOnefileAcl 'hello windows-acl-repair' 'runtime onefile ACL repair'
$repairedAcl = Get-Acl $cachedInner.FullName
$hasEveryone = $false
foreach ($rule in $repairedAcl.Access) {
    $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
    if ($sid -eq 'S-1-1-0') { $hasEveryone = $true }
}
if (-not $repairedAcl.AreAccessRulesProtected -or $hasEveryone) {
    throw "runtime onefile did not repair a legacy loose file ACL: $($repairedAcl.AccessToString)"
}
$pinMarker = Join-Path $env:TEMP 'luainstaller-onefile-pin.marker'
$pinRelease = Join-Path $env:TEMP 'luainstaller-onefile-pin.release'
Remove-Item -Force -ErrorAction SilentlyContinue $pinMarker, $pinRelease
$pinProbeExe = Join-Path $root 'pin-probe.exe'
$pinArguments = '"' + $pinMarker + '" "' + $pinRelease + '"'
$pinProcess = Start-Process -FilePath $pinProbeExe -ArgumentList $pinArguments -PassThru
for ($i = 0; $i -lt 100 -and -not (Test-Path $pinMarker); $i++) {
    if ($pinProcess.HasExited) { break }
    Start-Sleep -Milliseconds 100
}
if (-not (Test-Path $pinMarker) -or $pinProcess.HasExited) {
    throw 'onefile cache pin probe did not enter the inner process'
}
$pinInner = Get-Content -LiteralPath $pinMarker -Raw
$pinPayload = Split-Path -Parent $pinInner
$pinTargets = @(
    $pinPayload,
    (Join-Path $pinPayload '.luai'),
    (Join-Path $pinPayload '.luai\manifest.lua')
)
foreach ($pinTarget in $pinTargets) {
    $pinMoved = "$pinTarget.luai-swap-test"
    $moveSucceeded = $false
    try {
        Move-Item -LiteralPath $pinTarget -Destination $pinMoved -ErrorAction Stop
        $moveSucceeded = $true
    } catch {
        # Expected: the extractor retains no-delete handles until its child exits.
    }
    if ($moveSucceeded) {
        throw "onefile cache object was replaceable during execution: $pinTarget"
    }
}
[IO.File]::WriteAllBytes($pinRelease, [byte[]]@())
if (-not $pinProcess.WaitForExit(10000) -or $pinProcess.ExitCode -ne 0) {
    if (-not $pinProcess.HasExited) { Stop-Process -Id $pinProcess.Id -Force }
    throw 'onefile cache pin probe did not exit successfully'
}
Remove-Item -Force $pinMarker, $pinRelease
$pathArg = 'C:\Alpha Beta\trail'
$runtimeOnefilePath = Invoke-NativeChecked 'runtime onefile path' { & $runtimeOnefileExe $pathArg }
if (-not $runtimeOnefilePath.Contains("hello $pathArg")) {
    throw "runtime onefile changed a Windows path argument. Output: $runtimeOnefilePath"
}
$argvDriver = Join-Path $root 'argv-driver.exe'
$runtimeOnefileQuote = Invoke-NativeChecked 'runtime onefile quote' { & $argvDriver $runtimeOnefileExe quote }
Require-Match $runtimeOnefileQuote 'hello say "hello"\\tail' 'runtime onefile quote'
$runtimeOnefileTrailing = Invoke-NativeChecked 'runtime onefile trailing slash' { & $argvDriver $runtimeOnefileExe trailing }
Require-Match $runtimeOnefileTrailing 'hello C:\\Alpha Beta\\trail\\' 'runtime onefile trailing slash'
$runtimeOnefileEmpty = Invoke-NativeChecked 'runtime onefile empty argument' { & $argvDriver $runtimeOnefileExe empty }
Require-Match $runtimeOnefileEmpty '(?m)^hello\s*$' 'runtime onefile empty argument'

$students = Join-Path $env:TEMP 'luainstaller-win-students.json'
if (Test-Path $students) { Remove-Item -Force $students }
$studentExe = Join-Path $root 'student\student.exe'
$studentSeed = Invoke-NativeChecked 'student seed' { & $studentExe --data $students seed }
Require-Match $studentSeed 'Seeded 8 students' 'student seed'
$studentList = Invoke-NativeChecked 'student list' { & $studentExe --data $students list --sort average }
Require-Match $studentList 'Ada Lovelace' 'student list'

$studentsOnefile = Join-Path $env:TEMP 'luainstaller-win-students-onefile.json'
if (Test-Path $studentsOnefile) { Remove-Item -Force $studentsOnefile }
$studentOnefile = Join-Path $root 'student-onefile.exe'
$studentOnefileSeed = Invoke-NativeChecked 'student onefile seed' { & $studentOnefile --data $studentsOnefile seed }
Require-Match $studentOnefileSeed 'Seeded 8 students' 'student onefile seed'
$studentOnefileList = Invoke-NativeChecked 'student onefile list' { & $studentOnefile --data $studentsOnefile list --sort average }
Require-Match $studentOnefileList 'Ada Lovelace' 'student onefile list'

$db = Join-Path $env:TEMP 'luainstaller-win-savinglua.sqlite3'
if (Test-Path $db) { Remove-Item -Force $db }
$savinglua = Join-Path $root 'savinglua\savinglua.exe'
$savePutCommand = '"' + $savinglua + '" --db "' + $db + '" put users:ada "{\"name\":\"Ada Lovelace\",\"score\":98}"'
$savePut = Invoke-NativeChecked 'savinglua put' { cmd /c $savePutCommand }
Require-Match $savePut 'stored users:ada' 'savinglua put'
$saveGet = Invoke-NativeChecked 'savinglua get' { & $savinglua --db $db get users:ada }
Require-Match $saveGet 'Ada Lovelace' 'savinglua get'

$ltokeiExe = Join-Path $root 'ltokei\ltokei.exe'
$ltokeiPath = Join-Path $root 'ltokei\.luai'
$ltokei = Invoke-NativeChecked 'ltokei' { & $ltokeiExe $ltokeiPath }
Require-Match $ltokei 'Total' 'ltokei'

$firebirdPort = Get-Random -Minimum 20000 -Maximum 45000
$env:FIREBIRD_WEB_SQL_PORT = [string]$firebirdPort
$env:FIREBIRD_WEB_SQL_TOKEN = 'testtoken'
$firebird = Join-Path $root 'firebird\firebird.exe'
$outLog = Join-Path $env:TEMP 'luainstaller-win-firebird.out.log'
$errLog = Join-Path $env:TEMP 'luainstaller-win-firebird.err.log'
$proc = Start-Process -FilePath $firebird -WorkingDirectory (Split-Path $firebird) -NoNewWindow -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
try {
    $ok = $false
    for ($i = 0; $i -lt 80; $i++) {
        if ($proc.HasExited) {
            throw "firebird exited early: $(Get-Content $outLog -Raw) $(Get-Content $errLog -Raw)"
        }
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$firebirdPort/api/status" -Headers @{ 'X-Auth-Token' = 'testtoken' } -TimeoutSec 2
            if ($resp.Content -match '"ok":true') {
                $ok = $true
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    if (-not $ok) {
        throw "firebird status endpoint did not become ready: $(Get-Content $outLog -Raw) $(Get-Content $errLog -Raw)"
    }
} finally {
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force }
}

Write-Output 'windows remote bundles ok'
PS1
    # Convert C:/Users/... style paths to Windows backslash form for powershell -File.
    remote_ps1=$(printf '%s' "$REMOTE_TEMP/luainstaller-run-windows-bundles.ps1" | sed 's|/|\\|g')
    remote_temp_ps=$(printf '%s' "$REMOTE_TEMP" | sed 's|/|\\|g')
    for target in $WINDOWS_TARGETS; do
        label=${target%%=*}
        host=${target#*=}
        case "$host" in
            ''|-*)
                echo "unsafe Windows SSH target: $host" >&2
                exit 2
                ;;
        esac
        echo "windows remote target $label ($host)"
        preflight_windows_upload "$host"
        strict_scp "$archive" "$host:$REMOTE_TEMP/luainstaller-win-bundles.tar.gz" >/dev/null
        strict_scp "$runner" "$host:$REMOTE_TEMP/luainstaller-run-windows-bundles.ps1" >/dev/null
        strict_ssh "$host" "powershell -NoProfile -ExecutionPolicy Bypass -File \"$remote_ps1\" -StagingRoot \"$remote_temp_ps\" -BundleDirectoryName \"$win_out_name\""
    done
}

for safe_path in "$SOURCE_CACHE" "$WIN_PREFIX" "$WIN_TREE" "$WIN_OUT"; do
    require_safe_tmp_path "$safe_path"
done
WIN_OUT_NAME=$(basename "$WIN_OUT")
case "$WIN_OUT_NAME" in
    -*|*.)
        echo "unsafe Windows bundle directory name: $WIN_OUT_NAME" >&2
        exit 2
        ;;
esac
win_out_stem=${WIN_OUT_NAME%%.*}
win_out_stem_upper=$(printf '%s' "$win_out_stem" | tr '[:lower:]' '[:upper:]')
case "$win_out_stem_upper" in
    CON|PRN|AUX|NUL|CLOCK\$|COM[1-9]|LPT[1-9])
        echo "unsafe Windows bundle directory name: $WIN_OUT_NAME" >&2
        exit 2
        ;;
esac
require_safe_windows_temp "$REMOTE_TEMP"
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

need_cmd curl
need_cmd lua
need_cmd luarocks
need_cmd wine
need_cmd sha256sum
need_cmd x86_64-w64-mingw32-gcc
need_cmd x86_64-w64-mingw32-ar
need_cmd x86_64-w64-mingw32-ranlib

stage_source "$LUA_TARBALL" "https://www.lua.org/ftp/$LUA_TARBALL" "$LUA_SHA256"
stage_source "$LSQLITE3_ZIP" 'https://lua.sqlite.org/home/zip/lsqlite3_v096.zip?uuid=v0.9.6' "$LSQLITE3_SHA256"
stage_source "$SQLITE_ZIP" 'https://www.sqlite.org/2026/sqlite-amalgamation-3530200.zip' "$SQLITE_SHA256"
ensure_windows_lua
build_windows_deps
build_bundles
verify_with_wine
if [ "${WINDOWS_LOCAL_ONLY:-0}" = 1 ]; then
    echo "windows local Wine gate ok"
    exit 0
fi
run_remote_windows
