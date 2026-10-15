# Global WAU mod: let the desktop settle after logon, then reopen any app that was closed
# for an update and never came back.
#
# WAU captures this script's output and exit code: exit code 1 makes it re-run, and an
# output line that looks like {...} is parsed as an action. So every step runs with all
# streams discarded, failures are swallowed into the log, and $LASTEXITCODE is reset at the
# end (a helper that ran a native command could otherwise leave it non-zero). No `exit`:
# WAU may dot-source this file, and `exit` would then end its session.

try {
    . "$PSScriptRoot\gwm\lib\Load.ps1" *> $null
}
catch {
    $global:LASTEXITCODE = 0
    return
}

try {
    Wait-GwmSettle *> $null
}
catch {
    Write-GwmLog "Settle step failed: $($_.Exception.Message)" *> $null
}

try {
    Invoke-GwmReconcile *> $null
}
catch {
    Write-GwmLog "Reconcile step failed: $($_.Exception.Message)" *> $null
}

$global:LASTEXITCODE = 0
