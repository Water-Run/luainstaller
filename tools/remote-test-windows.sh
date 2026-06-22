#!/bin/sh
set -eu

WINDOWS_HOST=${WINDOWS_HOST:-"WaterRun@192.168.69.130"}
SSH_OPTS=${SSH_OPTS:-"-o StrictHostKeyChecking=no"}
REMOTE_TEMP=${REMOTE_TEMP:-"C:/Users/WaterRun/AppData/Local/Temp"}
SOURCE_CACHE=${SOURCE_CACHE:-"/tmp/luainstaller-source-cache"}
WIN_PREFIX=${WIN_PREFIX:-"/tmp/luainstaller-win-lua"}
WIN_TREE=${WIN_TREE:-"/tmp/luainstaller-win-rocks"}
WIN_OUT=${WIN_OUT:-"/tmp/luainstaller-win-bundles"}
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

LUA_VERSION=5.4.8
LUA_TARBALL=lua-$LUA_VERSION.tar.gz
LSQLITE3_ZIP=lsqlite3_v096.zip
SQLITE_ZIP=sqlite-amalgamation-3530200.zip

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing command: $1" >&2
        exit 1
    }
}

require_env() {
    name=$1
    eval "value=\${$name:-}"
    if [ -z "$value" ]; then
        echo "missing required environment variable: $name" >&2
        exit 1
    fi
}

stage_source() {
    name=$1
    url=$2
    mkdir -p "$SOURCE_CACHE"
    if [ ! -s "$SOURCE_CACHE/$name" ]; then
        curl -fL --connect-timeout 20 --max-time 180 -o "$SOURCE_CACHE/$name" "$url"
    fi
}

ensure_windows_lua() {
    if [ -x "$WIN_PREFIX/lua.exe" ] && [ -f "$WIN_PREFIX/bin/lua54.dll" ] && [ -f "$WIN_PREFIX/include/lua.h" ]; then
        return
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
        wine ./lua.exe -e 'package.path="Z:/tmp/luainstaller-win-rocks/share/lua/5.4/?.lua;Z:/tmp/luainstaller-win-rocks/share/lua/5.4/?/init.lua;"; package.cpath="Z:/tmp/luainstaller-win-rocks/lib/lua/5.4/?.dll;Z:/tmp/luainstaller-win-rocks/lib/lua/5.4/?/core.dll;"; require("cjson"); require("lfs"); require("lsqlite3"); require("socket.core"); require("pegasus"); print("windows deps ok")'
    )
}

bundle_demo() {
    entry=$1
    out=$2
    lua_path="$PROJECT_ROOT/src/?.lua;$PROJECT_ROOT/src/?/init.lua;$WIN_TREE/share/lua/5.4/?.lua;$WIN_TREE/share/lua/5.4/?/init.lua;;"
    lua_cpath="$WIN_TREE/lib/lua/5.4/?.dll;$WIN_TREE/lib/lua/5.4/?/core.dll;$WIN_TREE/lib/lua/5.4/?/init.dll;;"
    LUA_PATH="$lua_path" LUA_CPATH="$lua_cpath" \
        lua "$PROJECT_ROOT/src/cli.lua" b --dir "$PROJECT_ROOT/$entry" \
        -o "$out" --target-os windows --lua-prefix "$WIN_PREFIX" --max-deps 300
}

bundle_demo_onefile() {
    entry=$1
    out=$2
    lua_path="$PROJECT_ROOT/src/?.lua;$PROJECT_ROOT/src/?/init.lua;$WIN_TREE/share/lua/5.4/?.lua;$WIN_TREE/share/lua/5.4/?/init.lua;;"
    lua_cpath="$WIN_TREE/lib/lua/5.4/?.dll;$WIN_TREE/lib/lua/5.4/?/core.dll;$WIN_TREE/lib/lua/5.4/?/init.dll;;"
    LUA_PATH="$lua_path" LUA_CPATH="$lua_cpath" \
        lua "$PROJECT_ROOT/src/cli.lua" b --file "$PROJECT_ROOT/$entry" \
        -o "$out" --target-os windows --lua-prefix "$WIN_PREFIX" --max-deps 300
}

build_bundles() {
    rm -rf "$WIN_OUT"
    mkdir -p "$WIN_OUT"
    bundle_demo test/runtime_bundle/main.lua "$WIN_OUT/runtime"
    bundle_demo test/student_management_system/main.lua "$WIN_OUT/student"
    bundle_demo_onefile test/runtime_bundle/main.lua "$WIN_OUT/runtime-onefile"
    bundle_demo_onefile test/student_management_system/main.lua "$WIN_OUT/student-onefile"
    bundle_demo test/savinglua/main.lua "$WIN_OUT/savinglua"
    bundle_demo test/ltokei/main.lua "$WIN_OUT/ltokei"
    bundle_demo test/firebird_web_sql/server.lua "$WIN_OUT/firebird"
}

verify_with_wine() {
    rm -f /tmp/luainstaller-win-students.json /tmp/luainstaller-win-students-onefile.json /tmp/luainstaller-win-savinglua.sqlite3
    wine "$WIN_OUT/runtime/runtime.exe" wine-clean | grep "hello wine-clean"
    wine "$WIN_OUT/student/student.exe" --data Z:/tmp/luainstaller-win-students.json seed | grep "Seeded 8 students"
    wine "$WIN_OUT/student/student.exe" --data Z:/tmp/luainstaller-win-students.json list --sort average | grep "Ada Lovelace"
    wine "$WIN_OUT/runtime-onefile.exe" wine-onefile-clean | grep "hello wine-onefile-clean"
    wine "$WIN_OUT/student-onefile.exe" --data Z:/tmp/luainstaller-win-students-onefile.json seed | grep "Seeded 8 students"
    wine "$WIN_OUT/student-onefile.exe" --data Z:/tmp/luainstaller-win-students-onefile.json list --sort average | grep "Ada Lovelace"
    wine "$WIN_OUT/savinglua/savinglua.exe" --db Z:/tmp/luainstaller-win-savinglua.sqlite3 put users:ada '{"name":"Ada Lovelace","score":98}' | grep "stored users:ada"
    wine "$WIN_OUT/savinglua/savinglua.exe" --db Z:/tmp/luainstaller-win-savinglua.sqlite3 get users:ada | grep "Ada Lovelace"
    wine "$WIN_OUT/ltokei/ltokei.exe" Z:"$WIN_OUT/ltokei/.luai" | grep "Total"
    FIREBIRD_WEB_SQL_PORT=19124 FIREBIRD_WEB_SQL_TOKEN=testtoken wine "$WIN_OUT/firebird/firebird.exe" >/tmp/luainstaller-windows-firebird.log 2>&1 &
    pid=$!
    for _ in $(seq 1 60); do
        if curl -fsS http://127.0.0.1:19124/api/status -H "X-Auth-Token: testtoken" | grep '"ok":true' >/dev/null; then
            kill "$pid" >/dev/null 2>&1 || true
            wait "$pid" >/dev/null 2>&1 || true
            echo "windows wine firebird ok"
            return
        fi
        sleep 0.25
        if ! kill -0 "$pid" >/dev/null 2>&1; then
            cat /tmp/luainstaller-windows-firebird.log
            exit 1
        fi
    done
    cat /tmp/luainstaller-windows-firebird.log
    exit 1
}

run_remote_windows() {
    runner=/tmp/luainstaller-run-windows-bundles.ps1
    archive=/tmp/luainstaller-win-bundles.tar.gz
    rm -f "$archive" "$runner"
    tar -C /tmp -czf "$archive" "$(basename "$WIN_OUT")"
    cat >"$runner" <<'PS1'
$ErrorActionPreference = 'Stop'
$root = Join-Path $env:TEMP 'luainstaller-win-bundles'
if (Test-Path $root) { Remove-Item -Recurse -Force $root }
tar -xzf (Join-Path $env:TEMP 'luainstaller-win-bundles.tar.gz') -C $env:TEMP
$env:Path = 'C:\Windows\System32;C:\Windows'
$env:LUA_PATH = $null
$env:LUA_CPATH = $null

function Require-Match($Text, $Pattern, $Name) {
    if ($Text -notmatch $Pattern) {
        throw "$Name did not match $Pattern. Output: $Text"
    }
}

$runtime = & (Join-Path $root 'runtime\runtime.exe') 'windows-clean' | Out-String
Require-Match $runtime 'hello windows-clean' 'runtime'

$runtimeOnefile = & (Join-Path $root 'runtime-onefile.exe') 'windows-onefile-clean' | Out-String
Require-Match $runtimeOnefile 'hello windows-onefile-clean' 'runtime onefile'

$students = Join-Path $env:TEMP 'luainstaller-win-students.json'
if (Test-Path $students) { Remove-Item -Force $students }
$studentSeed = & (Join-Path $root 'student\student.exe') --data $students seed | Out-String
Require-Match $studentSeed 'Seeded 8 students' 'student seed'
$studentList = & (Join-Path $root 'student\student.exe') --data $students list --sort average | Out-String
Require-Match $studentList 'Ada Lovelace' 'student list'

$studentsOnefile = Join-Path $env:TEMP 'luainstaller-win-students-onefile.json'
if (Test-Path $studentsOnefile) { Remove-Item -Force $studentsOnefile }
$studentOnefile = Join-Path $root 'student-onefile.exe'
$studentOnefileSeed = & $studentOnefile --data $studentsOnefile seed | Out-String
Require-Match $studentOnefileSeed 'Seeded 8 students' 'student onefile seed'
$studentOnefileList = & $studentOnefile --data $studentsOnefile list --sort average | Out-String
Require-Match $studentOnefileList 'Ada Lovelace' 'student onefile list'

$db = Join-Path $env:TEMP 'luainstaller-win-savinglua.sqlite3'
if (Test-Path $db) { Remove-Item -Force $db }
$savinglua = Join-Path $root 'savinglua\savinglua.exe'
$savePutCommand = '"' + $savinglua + '" --db "' + $db + '" put users:ada "{\"name\":\"Ada Lovelace\",\"score\":98}"'
$savePut = cmd /c $savePutCommand | Out-String
Require-Match $savePut 'stored users:ada' 'savinglua put'
$saveGet = & $savinglua --db $db get users:ada | Out-String
Require-Match $saveGet 'Ada Lovelace' 'savinglua get'

$ltokei = & (Join-Path $root 'ltokei\ltokei.exe') (Join-Path $root 'ltokei\.luai') | Out-String
Require-Match $ltokei 'Total' 'ltokei'

$env:FIREBIRD_WEB_SQL_PORT = '19125'
$env:FIREBIRD_WEB_SQL_TOKEN = 'testtoken'
$firebird = Join-Path $root 'firebird\firebird.exe'
$outLog = Join-Path $env:TEMP 'luainstaller-win-firebird.out.log'
$errLog = Join-Path $env:TEMP 'luainstaller-win-firebird.err.log'
$proc = Start-Process -FilePath $firebird -WorkingDirectory (Split-Path $firebird) -NoNewWindow -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog
try {
    $ok = $false
    for ($i = 0; $i -lt 80; $i++) {
        try {
            $resp = Invoke-WebRequest -UseBasicParsing -Uri 'http://127.0.0.1:19125/api/status' -Headers @{ 'X-Auth-Token' = 'testtoken' } -TimeoutSec 2
            if ($resp.Content -match '"ok":true') {
                $ok = $true
                break
            }
        } catch {
            Start-Sleep -Milliseconds 250
        }
        if ($proc.HasExited) {
            throw "firebird exited early: $(Get-Content $outLog -Raw) $(Get-Content $errLog -Raw)"
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
    SSHPASS=$WINDOWS_PASSWORD sshpass -e scp $SSH_OPTS "$archive" "$WINDOWS_HOST:$REMOTE_TEMP/luainstaller-win-bundles.tar.gz" >/dev/null
    SSHPASS=$WINDOWS_PASSWORD sshpass -e scp $SSH_OPTS "$runner" "$WINDOWS_HOST:$REMOTE_TEMP/luainstaller-run-windows-bundles.ps1" >/dev/null
    SSHPASS=$WINDOWS_PASSWORD sshpass -e ssh $SSH_OPTS "$WINDOWS_HOST" "powershell -NoProfile -ExecutionPolicy Bypass -File C:\\Users\\WaterRun\\AppData\\Local\\Temp\\luainstaller-run-windows-bundles.ps1"
}

need_cmd curl
need_cmd lua
need_cmd luarocks
need_cmd wine
need_cmd sshpass
need_cmd x86_64-w64-mingw32-gcc
need_cmd x86_64-w64-mingw32-ar
need_cmd x86_64-w64-mingw32-ranlib
require_env WINDOWS_PASSWORD

stage_source "$LUA_TARBALL" "https://www.lua.org/ftp/$LUA_TARBALL"
stage_source "$LSQLITE3_ZIP" 'https://lua.sqlite.org/home/zip/lsqlite3_v096.zip?uuid=v0.9.6'
stage_source "$SQLITE_ZIP" 'https://www.sqlite.org/2026/sqlite-amalgamation-3530200.zip'
ensure_windows_lua
build_windows_deps
build_bundles
verify_with_wine
run_remote_windows
