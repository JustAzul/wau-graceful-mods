<#
.SYNOPSIS
    Removes what Install-WauGracefulMods.ps1 created.

.DESCRIPTION
    Deletes only the files listed in installed-files.json, unregisters the scheduled tasks and,
    with -RemoveWau, uninstalls WAU itself. Reopen markers and app-data backups under
    ProgramData are left alone. With -DryRun it prints the plan and changes nothing.

.PARAMETER DryRun
    Print the plan and exit.

.PARAMETER RemoveWau
    Also uninstall Winget-AutoUpdate with winget.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$RemoveWau
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'src\lib\Load.ps1')
. (Join-Path $PSScriptRoot 'Install.Helpers.ps1')

$wauId = 'Romanitho.Winget-AutoUpdate'
$prefix = '[do]  '
if ($DryRun) { $prefix = '[plan] ' }

function Write-Step {
    param([string]$Text)
    Write-Host ($prefix + $Text)
}

function Test-UnderFolder {
    param([string]$Path, [string]$Folder)
    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetFullPath($Folder).TrimEnd('\') + '\'
    $full.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)
}

$manifest = Import-GwmManifest -Path (Join-Path $repoRoot 'config\apps.psd1')
$taskApps = @($manifest.Apps | Where-Object { $_.Policy -eq 'close-reopen' -and $_.Scope -eq 'machine' })
$elevated = Test-GwmElevated

Write-Host ('wau-graceful-mods uninstaller, mode: ' + $(if ($DryRun) { 'dry run (nothing is changed)' } else { 'uninstall' }))
Write-Host ('elevated: ' + $elevated)

if (-not $DryRun -and -not $elevated) {
    Write-Host '[fail] not elevated: run from an elevated prompt'
    exit 1
}
if (-not $DryRun -and -not (Get-Command -Name Unregister-GwmTasks -ErrorAction SilentlyContinue)) {
    Write-Host '[fail] Unregister-GwmTasks is not available (src\lib\UserTasks.ps1 missing); nothing was changed'
    exit 1
}

$wauDir = Get-GwmWauInstallDir
$recordPath = $null
$record = $null
$removable = @()
if ($null -eq $wauDir) {
    Write-Host 'WAU is not installed: there are no files to remove.'
}
else {
    $modsDir = Join-Path $wauDir 'mods'
    $recordPath = Join-Path $modsDir 'gwm\installed-files.json'
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        try {
            $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
        }
        catch {
            Write-Host "[warn] $recordPath is unreadable; no files will be removed"
        }
    }
    else {
        Write-Host "[warn] no installed-files.json at $recordPath; no files will be removed"
    }
    if ($null -ne $record -and $null -ne $record.PSObject.Properties['Files']) {
        foreach ($f in @($record.Files)) {
            $listFile = Join-Path $wauDir 'included_apps.txt'
            # The record is trusted only for paths inside the folders the installer writes to.
            if ((Test-UnderFolder -Path $f -Folder $modsDir) -or ([System.IO.Path]::GetFullPath($f) -ieq [System.IO.Path]::GetFullPath($listFile))) {
                $removable += $f
            }
            else {
                Write-Host "[warn] ignoring a recorded path outside the WAU folders: $f"
            }
        }
    }
}

foreach ($app in $taskApps) {
    Write-Step ("unregister tasks '{0}-close' and '{0}-open' from {1}" -f $app.Process, $manifest.TaskFolder)
}
Write-Step ("remove the task folder {0} if it is empty after that" -f $manifest.TaskFolder)
if ($removable.Count -gt 0) {
    Write-Step ("delete {0} recorded files, then the record itself and any folder it leaves empty" -f $removable.Count)
}
if ($RemoveWau) {
    Write-Step "winget uninstall --id $wauId --exact --silent"
}
elseif ($null -ne $wauDir) {
    Write-Host 'WAU stays installed (use -RemoveWau to remove it). Its whitelist setting stays on, so with the list deleted it has no apps to update.'
}
Write-Host 'Reopen markers and app-data backups under ProgramData are left in place.'

if (-not $DryRun) {
    $null = Unregister-GwmTasks -Apps $taskApps -TaskFolder $manifest.TaskFolder
    if (Remove-GwmTaskFolderIfEmpty -TaskFolder $manifest.TaskFolder) {
        Write-Host ("removed the empty task folder {0}" -f $manifest.TaskFolder)
    }
    else {
        Write-Host ("task folder {0} left in place (absent or not empty)" -f $manifest.TaskFolder)
    }
    foreach ($f in $removable) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
    if ($null -ne $recordPath) {
        Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
        $gwmDir = Join-Path $modsDir 'gwm'
        foreach ($d in (Join-Path $gwmDir 'lib'), (Join-Path $gwmDir 'tasks'), $gwmDir) {
            if ((Test-Path -LiteralPath $d -PathType Container) -and @(Get-ChildItem -LiteralPath $d -Force).Count -eq 0) {
                Remove-Item -LiteralPath $d -Force
            }
        }
    }
    if ($RemoveWau) {
        & winget uninstall --id $wauId --exact --silent
        if ($LASTEXITCODE -ne 0) {
            Write-Host "[fail] winget uninstall failed with exit code $LASTEXITCODE"
            exit 1
        }
    }
}

Write-Host ''
if ($DryRun) { Write-Host 'Dry run finished. Nothing was changed.' } else { Write-Host 'Uninstalled.' }
exit 0
