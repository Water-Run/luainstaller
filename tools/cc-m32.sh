#!/bin/sh
set -eu

# A single executable compiler command lets luainstaller probe and use the
# same 32-bit target for every compile/link step on a 64-bit CI kernel.
exec "${LUAI_M32_CC:-cc}" -m32 "$@"
