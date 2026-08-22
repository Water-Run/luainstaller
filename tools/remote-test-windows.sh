#!/bin/sh
set -eu

# Compatibility launcher for environments that enter the Windows matrix from
# a POSIX orchestration shell. The required runner is native PowerShell with
# MSVC, either in GitHub Actions or a local Windows environment.
PROJECT_ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
RUNNER=$PROJECT_ROOT/tools/test-lua-versions.ps1

if command -v pwsh >/dev/null 2>&1; then
    exec pwsh -NoLogo -NoProfile -NonInteractive -File "$RUNNER" "$@"
fi
if command -v powershell.exe >/dev/null 2>&1; then
    exec powershell.exe -NoLogo -NoProfile -NonInteractive \
        -ExecutionPolicy Bypass -File "$RUNNER" "$@"
fi

echo 'native Windows PowerShell is required; run tools/test-lua-versions.ps1 on Windows or in the Windows CI job' >&2
exit 2
