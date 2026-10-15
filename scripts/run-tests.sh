#!/usr/bin/env bash
# Run the Pester suite on Windows PowerShell 5.1 from WSL.
#
# usage: scripts/run-tests.sh [tests/<Name>.Tests.ps1 ...]
#
# Each run copies the repository into a private directory under the Windows
# temp folder, so parallel runs never share a working copy and no UNC path is
# involved. The exit code is the number of failed tests (2 when Pester itself
# failed to run). GWM_STRICT=1 runs the suite under Set-StrictMode -Version 2, which
# the libraries must be safe under.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ps="/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
cmd="/mnt/c/Windows/System32/cmd.exe"

# %TEMP% comes back in 8.3 short form, which Set-Location refuses; derive the
# temp folder from the long %LOCALAPPDATA% instead.
localappdata="$("$cmd" /c 'echo %LOCALAPPDATA%' 2>/dev/null </dev/null | tr -d '\r')"
wintemp="$(wslpath -u "$localappdata")/Temp"
work="$(mktemp -d "$wintemp/gwm-tests.XXXXXX")"
trap 'rm -rf "$work"' EXIT

rsync -rt --delete --exclude '.git' "$repo/" "$work/"
winwork="$(wslpath -w "$work")"

if [ "$#" -eq 0 ]; then
    set -- tests
fi

paths=""
for p in "$@"; do
    paths="${paths}'${p//\'/\'\'}',"
done
paths="@(${paths%,})"

strict=""
if [ "${GWM_STRICT:-}" = "1" ]; then
    strict="Set-StrictMode -Version 2"
fi

"$ps" -NoProfile -ExecutionPolicy Bypass -Command "
    \$ErrorActionPreference = 'Stop'
    Set-Location -LiteralPath '${winwork}'
    if (\$PWD.ProviderPath -ne '${winwork}') { Write-Error 'tests must run from the private copy'; exit 2 }
    \$ErrorActionPreference = 'Continue'
    ${strict}
    \$r = Invoke-Pester -Path ${paths} -PassThru
    if (\$null -eq \$r) { exit 2 }
    exit ([int]\$r.FailedCount)
" </dev/null
