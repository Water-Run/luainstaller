#!/bin/sh
set -eu

BASTION=${BASTION:-"waterrun@192.168.10.40"}
BASTION_PORT=${BASTION_PORT:-"22222"}
MAC_HOST=${MAC_HOST:-"yymac06"}
REMOTE_ROOT=${REMOTE_ROOT:-"/tmp/luainstaller-mac-current"}
LUA_PREFIX=${LUA_PREFIX:-"/tmp/luainstaller-mac-lua-posix"}
PREFIX=${PREFIX:-"/tmp/luainstaller-mac-prefix"}
BUNDLE=${BUNDLE:-"/tmp/luainstaller-mac-runtime"}
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

remote() {
    ssh -p "$BASTION_PORT" "$BASTION" "ssh $MAC_HOST '$*'"
}

remote "set -eu
if [ ! -x \"$LUA_PREFIX/bin/lua\" ]; then
    rm -rf \"$LUA_PREFIX\" /tmp/lua-5.4.8 /tmp/lua-5.4.8.tar.gz
    cd /tmp
    curl -fsSLO https://www.lua.org/ftp/lua-5.4.8.tar.gz
    tar -xzf lua-5.4.8.tar.gz
    cd lua-5.4.8
    make clean >/tmp/luainstaller-macos-lua-clean.log 2>&1 || true
    make macosx >/tmp/luainstaller-macos-lua-build.log 2>&1
    make INSTALL_TOP=\"$LUA_PREFIX\" install >/tmp/luainstaller-macos-lua-install.log 2>&1
fi
\"$LUA_PREFIX/bin/lua\" -v"

tar --exclude=.git -C "$PROJECT_ROOT" -cf - . \
    | ssh -p "$BASTION_PORT" "$BASTION" "ssh $MAC_HOST 'rm -rf \"$REMOTE_ROOT\" && mkdir -p \"$REMOTE_ROOT\" && tar -xf - -C \"$REMOTE_ROOT\"'"

remote "set -eu
cd \"$REMOTE_ROOT\"
sh tools/install-source.sh --lua \"$LUA_PREFIX/bin/lua\" --prefix \"$PREFIX\"
rm -rf \"$BUNDLE\"
LUAI_LUA_PREFIX=\"$LUA_PREFIX\" \"$PREFIX/bin/luai\" -c --onedir test/runtime_bundle/main.lua -o \"$BUNDLE\" --max-deps 120
EXE=\"$BUNDLE/\$(basename \"$BUNDLE\")\"
env -i PATH=/usr/bin:/bin \"\$EXE\" macos-clean | grep \"hello macos-clean\"
"
