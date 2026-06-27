#!/bin/sh
set -eu

BASTION=${BASTION:-"waterrun@192.168.10.40"}
BASTION_PORT=${BASTION_PORT:-"22222"}
MAC_HOST=${MAC_HOST:-"yymac06"}
REMOTE_ROOT=${REMOTE_ROOT:-"/tmp/luainstaller-mac-current"}
LUA_PREFIX=${LUA_PREFIX:-"/tmp/luainstaller-mac-lua-posix"}
LUAROCKS_PREFIX=${LUAROCKS_PREFIX:-"/tmp/luainstaller-mac-luarocks"}
ROCKTREE=${ROCKTREE:-"/tmp/luainstaller-mac-rocktree"}
PREFIX=${PREFIX:-"/tmp/luainstaller-mac-prefix"}
SOURCE_CACHE=${SOURCE_CACHE:-"/tmp/luainstaller-source-cache"}
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
LUA_TARBALL=lua-5.4.8.tar.gz
LUA_URL=https://www.lua.org/ftp/$LUA_TARBALL
LUAROCKS_TARBALL=luarocks-3.12.2.tar.gz
LUAROCKS_URL=https://luarocks.org/releases/$LUAROCKS_TARBALL
LSQLITE3_ZIP=lsqlite3_v096.zip
SQLITE_ZIP=sqlite-amalgamation-3530200.zip
LSQLITE3_URL='https://lua.sqlite.org/home/zip/lsqlite3_v096.zip?uuid=v0.9.6'
SQLITE_URL='https://www.sqlite.org/2026/sqlite-amalgamation-3530200.zip'

quote_remote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}

stage_source() {
    name=$1
    url=$2
    mkdir -p "$SOURCE_CACHE"
    if [ ! -s "$SOURCE_CACHE/$name" ]; then
        curl -fL --connect-timeout 20 --max-time 180 -o "$SOURCE_CACHE/$name" "$url"
    fi
}

stage_macos_sources() {
    stage_source "$LUA_TARBALL" "$LUA_URL"
    stage_source "$LUAROCKS_TARBALL" "$LUAROCKS_URL"
    stage_source "$LSQLITE3_ZIP" "$LSQLITE3_URL"
    stage_source "$SQLITE_ZIP" "$SQLITE_URL"
    scp -P "$BASTION_PORT" \
        "$SOURCE_CACHE/$LUA_TARBALL" \
        "$SOURCE_CACHE/$LUAROCKS_TARBALL" \
        "$SOURCE_CACHE/$LSQLITE3_ZIP" \
        "$SOURCE_CACHE/$SQLITE_ZIP" \
        "$BASTION:/tmp/" >/dev/null
    mac_tmp=$(quote_remote "$MAC_HOST:/tmp/")
    ssh -p "$BASTION_PORT" "$BASTION" \
        "scp /tmp/$LUA_TARBALL /tmp/$LUAROCKS_TARBALL /tmp/$LSQLITE3_ZIP /tmp/$SQLITE_ZIP $mac_tmp" >/dev/null
}

copy_tree_macos() {
    mac_host=$(quote_remote "$MAC_HOST")
    remote_root=$(quote_remote "$REMOTE_ROOT")
    mac_cmd=$(quote_remote "rm -rf $remote_root && mkdir -p $remote_root && tar -xf - -C $remote_root")
    tar --exclude=.git -C "$PROJECT_ROOT" -cf - . \
        | ssh -p "$BASTION_PORT" "$BASTION" "ssh $mac_host $mac_cmd"
}

remote_sh() {
    mac_host=$(quote_remote "$MAC_HOST")
    ssh -p "$BASTION_PORT" "$BASTION" "ssh $mac_host 'sh -s'"
}

stage_macos_sources

remote_sh <<EOF
set -eu
LUA_PREFIX=$(quote_remote "$LUA_PREFIX")
LUAROCKS_PREFIX=$(quote_remote "$LUAROCKS_PREFIX")
ROCKTREE=$(quote_remote "$ROCKTREE")

if [ ! -x "\$LUA_PREFIX/bin/lua" ]; then
    rm -rf "\$LUA_PREFIX" /tmp/lua-5.4.8
    cd /tmp
    tar -xzf "$LUA_TARBALL"
    cd lua-5.4.8
    make clean >/tmp/luainstaller-macos-lua-clean.log 2>&1 || true
    make macosx >/tmp/luainstaller-macos-lua-build.log 2>&1
    make INSTALL_TOP="\$LUA_PREFIX" install >/tmp/luainstaller-macos-lua-install.log 2>&1
fi
"\$LUA_PREFIX/bin/lua" -v

if [ ! -x "\$LUAROCKS_PREFIX/bin/luarocks" ]; then
    rm -rf "\$LUAROCKS_PREFIX" /tmp/luarocks-3.12.2
    cd /tmp
    tar -xzf "$LUAROCKS_TARBALL"
    cd luarocks-3.12.2
    ./configure --prefix="\$LUAROCKS_PREFIX" --with-lua="\$LUA_PREFIX" >/tmp/luainstaller-macos-luarocks-configure.log
    make >/tmp/luainstaller-macos-luarocks-build.log
    make install >/tmp/luainstaller-macos-luarocks-install.log
fi
"\$LUAROCKS_PREFIX/bin/luarocks" --version

DEPS_LUA_PATH="\$ROCKTREE/share/lua/5.4/?.lua;\$ROCKTREE/share/lua/5.4/?/init.lua;;"
DEPS_LUA_CPATH="\$ROCKTREE/lib/lua/5.4/?.so;\$ROCKTREE/lib/lua/5.4/?/init.so;;"
if ! LUA_PATH="\$DEPS_LUA_PATH" LUA_CPATH="\$DEPS_LUA_CPATH" "\$LUA_PREFIX/bin/lua" -e 'require("cjson"); require("lfs"); require("socket.core"); require("pegasus")' >/tmp/luainstaller-macos-native-check.log 2>&1; then
    rm -rf "\$ROCKTREE"
    mkdir -p "\$ROCKTREE"
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force lua-cjson >/tmp/luainstaller-macos-cjson.log 2>&1
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force luafilesystem >/tmp/luainstaller-macos-lfs.log 2>&1
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force luasocket >/tmp/luainstaller-macos-luasocket.log 2>&1
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force pegasus >/tmp/luainstaller-macos-pegasus.log 2>&1
fi
if ! LUA_PATH="\$DEPS_LUA_PATH" LUA_CPATH="\$DEPS_LUA_CPATH" "\$LUA_PREFIX/bin/lua" -e 'require("lsqlite3")' >/tmp/luainstaller-macos-lsqlite-check.log 2>&1; then
    rm -rf /tmp/luainstaller-mac-lsqlite-build
    mkdir -p /tmp/luainstaller-mac-lsqlite-build "\$ROCKTREE/lib/lua/5.4"
    cd /tmp/luainstaller-mac-lsqlite-build
    cp "/tmp/$LSQLITE3_ZIP" ./lsqlite3.zip
    cp "/tmp/$SQLITE_ZIP" ./sqlite.zip
    unzip -q lsqlite3.zip -d lsqlite3-src
    unzip -q sqlite.zip
    LSQLITE_DIR=\$(find lsqlite3-src -name lsqlite3.c -exec dirname {} \\; | head -n 1)
    SQLITE_DIR=\$(find . -name sqlite3.c -exec dirname {} \\; | head -n 1)
    cc -bundle -undefined dynamic_lookup \
        -I"\$LUA_PREFIX/include" \
        -I"\$SQLITE_DIR" \
        -DLSQLITE_VERSION=\\"0.9.6\\" \
        "\$LSQLITE_DIR/lsqlite3.c" "\$SQLITE_DIR/sqlite3.c" \
        -o "\$ROCKTREE/lib/lua/5.4/lsqlite3.so"
fi
LUA_PATH="\$DEPS_LUA_PATH" LUA_CPATH="\$DEPS_LUA_CPATH" "\$LUA_PREFIX/bin/lua" -e 'require("cjson"); require("lfs"); require("socket.core"); require("pegasus"); require("lsqlite3"); print("mac native deps ok")'
EOF

copy_tree_macos

remote_sh <<EOF
set -eu
REMOTE_ROOT=$(quote_remote "$REMOTE_ROOT")
LUA_PREFIX=$(quote_remote "$LUA_PREFIX")
ROCKTREE=$(quote_remote "$ROCKTREE")
PREFIX=$(quote_remote "$PREFIX")
DEPS_LUA_PATH="\$ROCKTREE/share/lua/5.4/?.lua;\$ROCKTREE/share/lua/5.4/?/init.lua;;"
DEPS_LUA_CPATH="\$ROCKTREE/lib/lua/5.4/?.so;\$ROCKTREE/lib/lua/5.4/?/init.so;;"

bundle() {
    entry=\$1
    out=\$2
    LUA_PATH="\$DEPS_LUA_PATH" LUA_CPATH="\$DEPS_LUA_CPATH" LUAI_LUA_PREFIX="\$LUA_PREFIX" "\$PREFIX/bin/luainstaller" build --dir "\$entry" -o "\$out" --max-deps 250
}

bundle_onefile() {
    entry=\$1
    out=\$2
    LUA_PATH="\$DEPS_LUA_PATH" LUA_CPATH="\$DEPS_LUA_CPATH" LUAI_LUA_PREFIX="\$LUA_PREFIX" "\$PREFIX/bin/luainstaller" build --file "\$entry" -o "\$out" --max-deps 250
}

exe_path() {
    out=\$1
    printf '%s/%s' "\$out" "\$(basename "\$out")"
}

cd "\$REMOTE_ROOT"
sh tools/install-source.sh --lua "\$LUA_PREFIX/bin/lua" --prefix "\$PREFIX"

rm -rf /tmp/luainstaller-mac-runtime
bundle test/runtime_bundle/main.lua /tmp/luainstaller-mac-runtime
env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-runtime)" macos-clean | grep "hello macos-clean"

rm -rf /tmp/luainstaller-mac-student /tmp/macos-students.json
bundle test/student_management_system/main.lua /tmp/luainstaller-mac-student
env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-student)" --data /tmp/macos-students.json seed | grep "Seeded 8 students"
env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-student)" --data /tmp/macos-students.json list --sort average | grep "Ada Lovelace"

rm -rf /tmp/luainstaller-mac-onefile-runtime
bundle_onefile test/runtime_bundle/main.lua /tmp/luainstaller-mac-onefile-runtime
env -i PATH=/usr/bin:/bin /tmp/luainstaller-mac-onefile-runtime mac-onefile-runtime | grep "hello mac-onefile-runtime"

rm -rf /tmp/luainstaller-mac-onefile-student /tmp/macos-onefile-students.json
bundle_onefile test/student_management_system/main.lua /tmp/luainstaller-mac-onefile-student
env -i PATH=/usr/bin:/bin /tmp/luainstaller-mac-onefile-student --data /tmp/macos-onefile-students.json seed | grep "Seeded 8 students"
env -i PATH=/usr/bin:/bin /tmp/luainstaller-mac-onefile-student --data /tmp/macos-onefile-students.json list --sort average | grep "Ada Lovelace"

rm -rf /tmp/luainstaller-mac-savinglua /tmp/macos-savinglua.sqlite3
bundle test/savinglua/main.lua /tmp/luainstaller-mac-savinglua
env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-savinglua)" --db /tmp/macos-savinglua.sqlite3 put users:ada '{"name":"Ada Lovelace","score":98}' | grep "stored users:ada"
env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-savinglua)" --db /tmp/macos-savinglua.sqlite3 get users:ada | grep "Ada Lovelace"

rm -rf /tmp/luainstaller-mac-ltokei
bundle test/ltokei/main.lua /tmp/luainstaller-mac-ltokei
env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-ltokei)" /tmp/luainstaller-mac-ltokei/.luai | grep "Total"

rm -rf /tmp/luainstaller-mac-firebird
bundle test/firebird_web_sql/server.lua /tmp/luainstaller-mac-firebird
FIREBIRD_WEB_SQL_PORT=19123 FIREBIRD_WEB_SQL_TOKEN=testtoken env -i PATH=/usr/bin:/bin FIREBIRD_WEB_SQL_PORT=19123 FIREBIRD_WEB_SQL_TOKEN=testtoken "\$(exe_path /tmp/luainstaller-mac-firebird)" >/tmp/macos-firebird.log 2>&1 &
PID=\$!
trap 'kill "\$PID" >/dev/null 2>&1 || true' EXIT
for i in \$(seq 1 40); do
    if curl -fsS http://127.0.0.1:19123/api/status -H "X-Auth-Token: testtoken" | grep '"ok":true' >/dev/null; then
        kill "\$PID" >/dev/null 2>&1 || true
        wait "\$PID" >/dev/null 2>&1 || true
        echo "mac firebird ok"
        exit 0
    fi
    sleep 0.25
    if ! kill -0 "\$PID" >/dev/null 2>&1; then
        cat /tmp/macos-firebird.log
        exit 1
    fi
done
cat /tmp/macos-firebird.log
exit 1
EOF
