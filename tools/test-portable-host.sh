#!/bin/sh
set -eu

# Native supplemental gate for FreeBSD and Android/Termux. It intentionally
# uses only the checked-out source and the host's selected official Lua ABI.
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$PROJECT_ROOT"

LUA=${LUAI_TEST_LUA:-lua}
if [ -n "${TERMUX_VERSION:-}" ]; then
    termux_prefix=${TERMUX__PREFIX:-${PREFIX:-${TERMUX_PREFIX:-}}}
    : "${termux_prefix:?Termux prefix environment is required}"
    PREFIX=${PREFIX:-$termux_prefix}
    TMPDIR=${TMPDIR:-$termux_prefix/tmp}
    export PREFIX TMPDIR
fi

"$LUA" test/lua_abi.lua
"$LUA" test/version_contract.lua
"$LUA" test/toolchain_native.lua
"$LUA" test/native_bundle.lua
"$LUA" test/native_onefile.lua
"$LUA" test/onefile_lifecycle.lua

"$LUA" - <<'LUA'
local harness = dofile("test/support/harness.lua")
harness.install_loader()
local host = require("luainstaller.platform").detectHost()
if os.getenv("TERMUX_VERSION") then
    assert(host.os == "android", "Termux was not classified as Android")
elseif tostring(harness.command_output_trimmed("uname -s")) == "FreeBSD" then
    assert(host.os == "freebsd", "FreeBSD was not classified correctly")
end
io.write("portable host ok: ", host.os, " ", host.arch, "\n")
LUA
