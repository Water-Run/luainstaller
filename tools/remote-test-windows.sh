#!/bin/sh
set -eu

# Compatibility launcher for environments that enter the Windows matrix from
# a POSIX orchestration shell. The release gate itself is native PowerShell and
# runs directly on the physical Windows host with its native compiler.
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RUNNER=$PROJECT_ROOT/tools/test-lua-versions.ps1

if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoLogo -NoProfile -NonInteractive -File "$RUNNER" "$@"
fi
if command -v powershell.exe >/dev/null 2>&1; then
    exec powershell.exe -NoLogo -NoProfile -NonInteractive \
        -ExecutionPolicy Bypass -File "$RUNNER" "$@"
fi

echo 'native Windows PowerShell is required; run tools/test-lua-versions.ps1 on the physical Windows host' >&2
exit 2
