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
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
LUA_TARBALL=lua-5.4.8.tar.gz
LUA_URL=https://www.lua.org/ftp/$LUA_TARBALL
LUAROCKS_TARBALL=luarocks-3.13.0.tar.gz
LUAROCKS_URL=https://luarocks.org/releases/$LUAROCKS_TARBALL
LSQLITE3_ZIP=lsqlite3_v096.zip
SQLITE_ZIP=sqlite-amalgamation-3530200.zip
LSQLITE3_URL='https://lua.sqlite.org/home/zip/lsqlite3_v096.zip?uuid=v0.9.6'
SQLITE_URL='https://www.sqlite.org/2026/sqlite-amalgamation-3530200.zip'
LUA_SHA256=4f18ddae154e793e46eeab727c59ef1c0c0c2b744e7b94219710d76f530629ae
LUAROCKS_SHA256=245bf6ec560c042cb8948e3d661189292587c5949104677f1eecddc54dbe7e37
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

quote_remote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
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

stage_macos_sources() {
    stage_source "$LUA_TARBALL" "$LUA_URL" "$LUA_SHA256"
    stage_source "$LUAROCKS_TARBALL" "$LUAROCKS_URL" "$LUAROCKS_SHA256"
    stage_source "$LSQLITE3_ZIP" "$LSQLITE3_URL" "$LSQLITE3_SHA256"
    stage_source "$SQLITE_ZIP" "$SQLITE_URL" "$SQLITE_SHA256"
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
    ssh -p "$BASTION_PORT" "$BASTION" "ssh $mac_host $mac_cmd" \
        <"$TRACKED_ARCHIVE"
}

create_tracked_tree_archive() {
    TRACKED_ARCHIVE=$SOURCE_CACHE/tracked-tree.$$.tar
    rm -f "$TRACKED_ARCHIVE"
    (cd "$PROJECT_ROOT" && git archive --format=tar HEAD) >"$TRACKED_ARCHIVE"
}

remote_sh() {
    mac_host=$(quote_remote "$MAC_HOST")
    ssh -p "$BASTION_PORT" "$BASTION" "ssh $mac_host 'sh -s'"
}

check_remote_macos_tmp_path() {
    mac_host=$(quote_remote "$MAC_HOST")
    checked_path=$(quote_remote "$1")
    ssh -p "$BASTION_PORT" "$BASTION" \
        "ssh $mac_host CHECK_PATH=$checked_path sh -s" <<'EOF'
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
EOF
}

for safe_path in "$REMOTE_ROOT" "$LUA_PREFIX" "$LUAROCKS_PREFIX" "$ROCKTREE" \
    "$PREFIX" "$SOURCE_CACHE"; do
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

stage_macos_sources

for remote_path in "$REMOTE_ROOT" "$LUA_PREFIX" "$LUAROCKS_PREFIX" "$ROCKTREE" "$PREFIX"; do
    check_remote_macos_tmp_path "$remote_path"
done

remote_sh <<EOF
set -eu
LUA_PREFIX=$(quote_remote "$LUA_PREFIX")
LUAROCKS_PREFIX=$(quote_remote "$LUAROCKS_PREFIX")
ROCKTREE=$(quote_remote "$ROCKTREE")
LUA_SHA256=$LUA_SHA256
LUAROCKS_SHA256=$LUAROCKS_SHA256
LSQLITE3_SHA256=$LSQLITE3_SHA256
SQLITE_SHA256=$SQLITE_SHA256

command -v shasum >/dev/null 2>&1 || {
    echo "missing macOS command: shasum" >&2
    exit 1
}

verify_source() {
    expected=\$1
    source_path=\$2
    actual=\$(shasum -a 256 "\$source_path" | awk '{ print \$1 }')
    if [ "\$actual" != "\$expected" ]; then
        echo "source archive hash mismatch: \$source_path" >&2
        exit 1
    fi
}
verify_source "\$LUA_SHA256" "/tmp/$LUA_TARBALL"
verify_source "\$LUAROCKS_SHA256" "/tmp/$LUAROCKS_TARBALL"
verify_source "\$LSQLITE3_SHA256" "/tmp/$LSQLITE3_ZIP"
verify_source "\$SQLITE_SHA256" "/tmp/$SQLITE_ZIP"

if [ ! -x "\$LUA_PREFIX/bin/lua" ] \
    || ! "\$LUA_PREFIX/bin/lua" -v 2>&1 | grep '^Lua 5\.4\.8 ' >/dev/null; then
    rm -rf "\$LUA_PREFIX" /tmp/luainstaller-mac-lua-build
    mkdir -p /tmp/luainstaller-mac-lua-build
    tar -xzf "/tmp/$LUA_TARBALL" -C /tmp/luainstaller-mac-lua-build
    cd /tmp/luainstaller-mac-lua-build/lua-5.4.8
    make clean >/tmp/luainstaller-macos-lua-clean.log 2>&1 || true
    make macosx >/tmp/luainstaller-macos-lua-build.log 2>&1
    make INSTALL_TOP="\$LUA_PREFIX" install >/tmp/luainstaller-macos-lua-install.log 2>&1
fi
"\$LUA_PREFIX/bin/lua" -v
test "\$("\$LUA_PREFIX/bin/lua" -e 'io.write(_VERSION)')" = "Lua 5.4"

if [ ! -x "\$LUAROCKS_PREFIX/bin/luarocks" ] \
    || ! "\$LUAROCKS_PREFIX/bin/luarocks" --version | grep '3\.12\.2' >/dev/null; then
    rm -rf "\$LUAROCKS_PREFIX" /tmp/luainstaller-mac-luarocks-build
    mkdir -p /tmp/luainstaller-mac-luarocks-build
    tar -xzf "/tmp/$LUAROCKS_TARBALL" -C /tmp/luainstaller-mac-luarocks-build
    cd /tmp/luainstaller-mac-luarocks-build/luarocks-3.12.2
    ./configure --prefix="\$LUAROCKS_PREFIX" --with-lua="\$LUA_PREFIX" >/tmp/luainstaller-macos-luarocks-configure.log
    make >/tmp/luainstaller-macos-luarocks-build.log
    make install >/tmp/luainstaller-macos-luarocks-install.log
fi
"\$LUAROCKS_PREFIX/bin/luarocks" --version

DEPS_LUA_PATH="\$ROCKTREE/share/lua/5.4/?.lua;\$ROCKTREE/share/lua/5.4/?/init.lua;;"
DEPS_LUA_CPATH="\$ROCKTREE/lib/lua/5.4/?.so;\$ROCKTREE/lib/lua/5.4/?/init.so;;"
deps_ready=true
for pinned_dependency in \
    'lua-cjson 2.1.0.10-1' \
    'luafilesystem 1.9.0-1' \
    'luasocket 3.1.0-1' \
    'mimetypes 1.1.0-2' \
    'pegasus 1.1.0-0'; do
    if ! "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" \
        show \$pinned_dependency >/dev/null 2>&1; then
        deps_ready=false
    fi
done
if [ "\$deps_ready" != true ] \
    || ! LUA_PATH="\$DEPS_LUA_PATH" LUA_CPATH="\$DEPS_LUA_CPATH" "\$LUA_PREFIX/bin/lua" \
        -e 'require("cjson"); require("lfs"); require("socket.core"); require("mimetypes"); require("pegasus")' \
        >/tmp/luainstaller-macos-native-check.log 2>&1; then
    rm -rf "\$ROCKTREE"
    mkdir -p "\$ROCKTREE"
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force lua-cjson 2.1.0.10-1 >/tmp/luainstaller-macos-cjson.log 2>&1
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force luafilesystem 1.9.0-1 >/tmp/luainstaller-macos-lfs.log 2>&1
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force luasocket 3.1.0-1 >/tmp/luainstaller-macos-luasocket.log 2>&1
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force mimetypes 1.1.0-2 >/tmp/luainstaller-macos-mimetypes.log 2>&1
    "\$LUAROCKS_PREFIX/bin/luarocks" --tree "\$ROCKTREE" install --force pegasus 1.1.0-0 >/tmp/luainstaller-macos-pegasus.log 2>&1
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
LUA_PATH="\$DEPS_LUA_PATH" LUA_CPATH="\$DEPS_LUA_CPATH" "\$LUA_PREFIX/bin/lua" -e 'require("cjson"); require("lfs"); require("socket.core"); require("mimetypes"); require("pegasus"); require("lsqlite3"); print("mac native deps ok")'
EOF

create_tracked_tree_archive
trap 'rm -f "$TRACKED_ARCHIVE"' EXIT HUP INT TERM
copy_tree_macos
rm -f "$TRACKED_ARCHIVE"
trap - EXIT HUP INT TERM

remote_sh <<EOF
set -eu
REMOTE_ROOT=$(quote_remote "$REMOTE_ROOT")
LUA_PREFIX=$(quote_remote "$LUA_PREFIX")
LUAROCKS_PREFIX=$(quote_remote "$LUAROCKS_PREFIX")
ROCKTREE=$(quote_remote "$ROCKTREE")
PREFIX=$(quote_remote "$PREFIX")
MATRIX_HOST_LABEL=$(quote_remote "$MAC_HOST")
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
HOST_LABEL="\$MATRIX_HOST_LABEL" sh tools/test-lua-versions.sh
PATH="\$LUAROCKS_PREFIX/bin:\$LUA_PREFIX/bin:\$PATH" \
    "\$LUAROCKS_PREFIX/bin/luarocks" make --force --tree "\$PREFIX" \
    luainstaller-1.0.0-1.rockspec
PATH="\$LUAROCKS_PREFIX/bin:\$LUA_PREFIX/bin:\$PATH"
LUA_PATH="\$DEPS_LUA_PATH"
LUA_CPATH="\$DEPS_LUA_CPATH"
LUAI_LUA_PREFIX="\$LUA_PREFIX"
export PATH LUA_PATH LUA_CPATH LUAI_LUA_PREFIX
"\$LUA_PREFIX/bin/lua" test/cli_split_smoke.lua
"\$LUA_PREFIX/bin/lua" test/contract_docs.lua
smoke_output=\$("\$LUA_PREFIX/bin/lua" test/smoke_all.lua)
printf '%s\n' "\$smoke_output"
if printf '%s\n' "\$smoke_output" | grep -i 'skipped' >/dev/null; then
    echo "macOS smoke suite reported a skipped probe" >&2
    exit 1
fi

rm -rf /tmp/luainstaller-mac-runtime
bundle test/runtime_bundle/main.lua /tmp/luainstaller-mac-runtime
output=\$(env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-runtime)" macos-clean)
printf '%s\n' "\$output" | grep "hello macos-clean"

rm -rf /tmp/luainstaller-mac-student
rm -f /tmp/luainstaller-macos-students.json
bundle test/student_management_system/main.lua /tmp/luainstaller-mac-student
output=\$(env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-student)" --data /tmp/luainstaller-macos-students.json seed)
printf '%s\n' "\$output" | grep "Seeded 8 students"
output=\$(env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-student)" --data /tmp/luainstaller-macos-students.json list --sort average)
printf '%s\n' "\$output" | grep "Ada Lovelace"

rm -rf /tmp/luainstaller-mac-onefile-runtime
bundle_onefile test/runtime_bundle/main.lua /tmp/luainstaller-mac-onefile-runtime
runtime_onefile_hash=\$(shasum -a 256 /tmp/luainstaller-mac-onefile-runtime | awk '{ print \$1 }')
rm -f /tmp/luainstaller-mac-onefile-runtime
bundle_onefile test/runtime_bundle/main.lua /tmp/luainstaller-mac-onefile-runtime
rebuilt_onefile_hash=\$(shasum -a 256 /tmp/luainstaller-mac-onefile-runtime | awk '{ print \$1 }')
test "\$runtime_onefile_hash" = "\$rebuilt_onefile_hash"
echo "macOS onefile reproducibility ok"
output=\$(env -i PATH=/usr/bin:/bin /tmp/luainstaller-mac-onefile-runtime mac-onefile-runtime)
printf '%s\n' "\$output" | grep "hello mac-onefile-runtime"

rm -rf /tmp/luainstaller-mac-onefile-student
rm -f /tmp/luainstaller-macos-onefile-students.json
bundle_onefile test/student_management_system/main.lua /tmp/luainstaller-mac-onefile-student
output=\$(env -i PATH=/usr/bin:/bin /tmp/luainstaller-mac-onefile-student --data /tmp/luainstaller-macos-onefile-students.json seed)
printf '%s\n' "\$output" | grep "Seeded 8 students"
output=\$(env -i PATH=/usr/bin:/bin /tmp/luainstaller-mac-onefile-student --data /tmp/luainstaller-macos-onefile-students.json list --sort average)
printf '%s\n' "\$output" | grep "Ada Lovelace"

rm -rf /tmp/luainstaller-mac-savinglua
rm -f /tmp/luainstaller-macos-savinglua.sqlite3
bundle test/savinglua/main.lua /tmp/luainstaller-mac-savinglua
output=\$(env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-savinglua)" --db /tmp/luainstaller-macos-savinglua.sqlite3 put users:ada '{"name":"Ada Lovelace","score":98}')
printf '%s\n' "\$output" | grep "stored users:ada"
output=\$(env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-savinglua)" --db /tmp/luainstaller-macos-savinglua.sqlite3 get users:ada)
printf '%s\n' "\$output" | grep "Ada Lovelace"

rm -rf /tmp/luainstaller-mac-ltokei
bundle test/ltokei/main.lua /tmp/luainstaller-mac-ltokei
output=\$(env -i PATH=/usr/bin:/bin "\$(exe_path /tmp/luainstaller-mac-ltokei)" /tmp/luainstaller-mac-ltokei/.luai)
printf '%s\n' "\$output" | grep "Total"

rm -rf /tmp/luainstaller-mac-firebird
bundle test/firebird_web_sql/server.lua /tmp/luainstaller-mac-firebird
PORT=\$((20000 + \$\$ % 20000))
env -i PATH=/usr/bin:/bin FIREBIRD_WEB_SQL_PORT="\$PORT" FIREBIRD_WEB_SQL_TOKEN=testtoken "\$(exe_path /tmp/luainstaller-mac-firebird)" >/tmp/luainstaller-macos-firebird.log 2>&1 &
PID=\$!
trap 'kill "\$PID" >/dev/null 2>&1 || true' EXIT
for i in \$(seq 1 40); do
    if ! kill -0 "\$PID" >/dev/null 2>&1; then
        cat /tmp/luainstaller-macos-firebird.log
        exit 1
    fi
    response=\$(curl -fsS "http://127.0.0.1:\$PORT/api/status" -H "X-Auth-Token: testtoken" 2>/dev/null || true)
    if printf '%s\n' "\$response" | grep '"ok":true' >/dev/null; then
        kill "\$PID" >/dev/null 2>&1 || true
        wait "\$PID" >/dev/null 2>&1 || true
        echo "mac firebird ok"
        exit 0
    fi
    sleep 0.25
done
cat /tmp/luainstaller-macos-firebird.log
exit 1
EOF
