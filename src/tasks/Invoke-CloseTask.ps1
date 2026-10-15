# Scheduled-task wrapper that closes one app inside the desktop user's session.
# Exit codes: 0 the process is gone, 1 it is still running (or the close failed).
# A library is dot-sourced only when its function is not defined yet, so a test can predefine a fake.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProcessName,
    [int]$TimeoutSec = 30,
    [string]$ManifestPath
)

$libDir = Join-Path $PSScriptRoot '..\lib'
foreach ($needed in @(
        @{ Function = 'Write-GwmLog'; File = 'Log.ps1' },
        @{ Function = 'Import-GwmManifest'; File = 'Manifest.ps1' },
        @{ Function = 'Close-App'; File = 'CloseApp.ps1' })) {
    if (-not (Get-Command -Name $needed.Function -CommandType Function -ErrorAction SilentlyContinue)) {
        . (Join-Path $libDir $needed.File)
    }
}

if (-not $ManifestPath) {
    $ManifestPath = Join-Path $PSScriptRoot '..\apps.psd1'
}

# Hidden-window classes only widen what Close-App may target, so any trouble reading the
# manifest means "no extra targets" and the close still goes ahead.
$hiddenClasses = @()
try {
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "manifest not found: $ManifestPath"
    }
    $manifest = Import-GwmManifest -Path $ManifestPath
    foreach ($app in @($manifest.Apps)) {
        if ([string]$app.Process -ieq $ProcessName) {
            if ($app.ContainsKey('HiddenWindowClass')) {
                $hiddenClasses = @($app.HiddenWindowClass | Where-Object { $_ })
            }
            break
        }
    }
}
catch {
    Write-GwmLog "No hidden window classes for $ProcessName ($($_.Exception.Message))"
    $hiddenClasses = @()
}

$closeArgs = @{ ProcessName = $ProcessName; TimeoutSec = $TimeoutSec }
if ($hiddenClasses.Count -gt 0) {
    $closeArgs.HiddenWindowClass = [string[]]$hiddenClasses
}

try {
    $result = @(Close-App @closeArgs | Where-Object { $_ }) | Select-Object -Last 1
}
catch {
    Write-GwmLog "Close-App failed for ${ProcessName}: $($_.Exception.Message)"
    exit 1
}

if ($result -and $result.Exited) {
    exit 0
}
exit 1
