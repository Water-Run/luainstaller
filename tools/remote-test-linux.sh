#!/bin/sh
set -eu

LINUX_X64=${LINUX_X64:-"waterrun@192.168.10.40"}
LINUX_X64_PORT=${LINUX_X64_PORT:-"22222"}
LINUX_ARM64=${LINUX_ARM64:-"lyf@192.168.5.19"}
REMOTE_ROOT=${REMOTE_ROOT:-"/tmp/luainstaller-linux-current"}
PROJECT_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

copy_tree_ssh() {
    target=$1
    port=$2
    remote_root=$3
    tar --exclude=.git -C "$PROJECT_ROOT" -cf - . \
        | ssh -p "$port" "$target" "rm -rf '$remote_root' && mkdir -p '$remote_root' && tar -xf - -C '$remote_root'"
}

copy_tree_default_ssh() {
    target=$1
    remote_root=$2
    tar --exclude=.git -C "$PROJECT_ROOT" -cf - . \
        | ssh "$target" "rm -rf '$remote_root' && mkdir -p '$remote_root' && tar -xf - -C '$remote_root'"
}

copy_tree_ssh "$LINUX_X64" "$LINUX_X64_PORT" "$REMOTE_ROOT"

ssh -p "$LINUX_X64_PORT" "$LINUX_X64" "sh -s" <<EOF
set -eu
cd "$REMOTE_ROOT"
luac -p src/*.lua test/smoke_all.lua
lua test/smoke_all.lua
rm -rf /tmp/luainstaller-linux-source-prefix /tmp/luainstaller-linux-runtime
sh tools/install-source.sh --prefix /tmp/luainstaller-linux-source-prefix
/tmp/luainstaller-linux-source-prefix/bin/luai --version
/tmp/luainstaller-linux-source-prefix/bin/luai -c --onedir test/runtime_bundle/main.lua -o /tmp/luainstaller-linux-runtime --max-deps 120
env -i PATH=/usr/bin:/bin /tmp/luainstaller-linux-runtime/luainstaller-linux-runtime linux-clean | grep "hello linux-clean"
echo "linux x64 remote ok"
EOF

copy_tree_default_ssh "$LINUX_ARM64" "$REMOTE_ROOT"

ssh "$LINUX_ARM64" "sh -s" <<EOF
set -eu
cd "$REMOTE_ROOT"
rm -rf /tmp/luainstaller-linux-arm64-source-prefix /tmp/luainstaller-linux-arm64-runtime
sh tools/install-source.sh --prefix /tmp/luainstaller-linux-arm64-source-prefix
/tmp/luainstaller-linux-arm64-source-prefix/bin/luai --version
/tmp/luainstaller-linux-arm64-source-prefix/bin/luai -a test/runtime_bundle/main.lua --max-deps 120
if /tmp/luainstaller-linux-arm64-source-prefix/bin/luai -c --onedir test/runtime_bundle/main.lua -o /tmp/luainstaller-linux-arm64-runtime --max-deps 120 >/tmp/luainstaller-linux-arm64-bundle.out 2>&1; then
    env -i PATH=/usr/bin:/bin /tmp/luainstaller-linux-arm64-runtime/luainstaller-linux-arm64-runtime arm64-clean | grep "hello arm64-clean"
else
    grep "ToolchainError" /tmp/luainstaller-linux-arm64-bundle.out
fi
echo "linux arm64 remote ok"
EOF
