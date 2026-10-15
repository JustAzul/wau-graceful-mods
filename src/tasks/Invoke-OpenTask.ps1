# Scheduled-task wrapper that starts one app inside the desktop user's session.
# Exit codes: 0 the process runs (already, or started now), 2 the exe does not exist,
# 3 starting the exe failed.
# A library is dot-sourced only when its function is not defined yet, so a test can predefine a fake.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProcessName,
    [Parameter(Mandatory = $true)][string]$ExePath
)

$libDir = Join-Path $PSScriptRoot '..\lib'
foreach ($needed in @(
        @{ Function = 'Write-GwmLog'; File = 'Log.ps1' },
        @{ Function = 'Test-GwmProcessRunning'; File = 'Process.ps1' })) {
    if (-not (Get-Command -Name $needed.Function -CommandType Function -ErrorAction SilentlyContinue)) {
        . (Join-Path $libDir $needed.File)
    }
}

if (Test-GwmProcessRunning -ProcessName $ProcessName) {
    Write-GwmLog "$ProcessName is already running; nothing to open"
    exit 0
}

if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    Write-GwmLog "Executable not found: $ExePath"
    exit 2
}

try {
    Start-Process -FilePath $ExePath -WorkingDirectory (Split-Path -Parent $ExePath) -ErrorAction Stop
}
catch {
    Write-GwmLog "Could not start ${ExePath}: $($_.Exception.Message)"
    exit 3
}
exit 0
