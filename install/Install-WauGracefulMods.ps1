<#
.SYNOPSIS
    Installs Winget-AutoUpdate (WAU) with the graceful-mods runtime on top of it.

.DESCRIPTION
    Run it from an elevated prompt, as the desktop user. With -DryRun it only prints what it
    would do, changes nothing and works without elevation. Re-running is safe.

.PARAMETER DryRun
    Print the plan and exit. Nothing is installed, written or registered.

.PARAMETER ManifestPath
    App manifest to install. Defaults to config\apps.psd1 in this repository.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [string]$ManifestPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$repoRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repoRoot 'src\lib\Load.ps1')
. (Join-Path $PSScriptRoot 'Install.Helpers.ps1')
if (-not $ManifestPath) {
    $ManifestPath = Join-Path $repoRoot 'config\apps.psd1'
}

$wauId = 'Romanitho.Winget-AutoUpdate'
$prefix = '[do]  '
if ($DryRun) { $prefix = '[plan] ' }

function Write-Step {
    param([string]$Text)
    Write-Host ($prefix + $Text)
}

function Stop-Install {
    param([string]$Text)
    Write-Host ('[fail] ' + $Text)
    exit 1
}

$manifest = Import-GwmManifest -Path $ManifestPath
$taskApps = @($manifest.Apps | Where-Object { $_.Policy -eq 'close-reopen' -and $_.Scope -eq 'machine' })
$elevated = Test-GwmElevated
$user = Get-GwmInteractiveUser

Write-Host ('wau-graceful-mods installer, mode: ' + $(if ($DryRun) { 'dry run (nothing is changed)' } else { 'install' }))
Write-Host ('elevated: ' + $elevated)

# Preflight: every check that can be done before the first change.
$blockers = @()
if (-not $elevated) { $blockers += 'not elevated: run from an elevated prompt' }
if ($null -eq $user) {
    $blockers += 'no desktop user found (no explorer.exe): run from the desktop session'
}
elseif ($elevated -and ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne $user.UserSid)) {
    $blockers += 'the elevated identity is not the desktop user: elevate with the desktop account'
}
foreach ($required in 'src\mods\_WAU-mods.ps1', 'src\tasks\Invoke-CloseTask.ps1', 'src\tasks\Invoke-OpenTask.ps1', 'src\lib\Load.ps1') {
    if (-not (Test-Path -LiteralPath (Join-Path $repoRoot $required) -PathType Leaf)) {
        $blockers += "repository file missing: $required"
    }
}
if (-not (Get-Command -Name Register-GwmTasks -ErrorAction SilentlyContinue)) {
    $blockers += 'Register-GwmTasks is not available (src\lib\UserTasks.ps1 missing)'
}
$wauDir = Get-GwmWauInstallDir
if ($null -eq $wauDir -and -not (Get-Command -Name winget -ErrorAction SilentlyContinue)) {
    $blockers += 'WAU is not installed and winget was not found'
}

if ($blockers.Count -gt 0) {
    foreach ($b in $blockers) { Write-Host ('[block] ' + $b) }
    if (-not $DryRun) {
        Stop-Install 'preflight failed, nothing was changed'
    }
    Write-Host '[plan] the blockers above would stop a real run'
}

$changes = @()
$files = @()

# 0. Runtime data folders. ProgramData lets standard users create subfolders, so they are
# created and locked to SYSTEM and Administrators before anything else can write there.
$dataRoot = Join-Path $env:ProgramData 'wau-graceful-mods'
Write-Step "create $dataRoot\state and \backups, remove inheritance, allow only SYSTEM and Administrators (owner: Administrators), then verify the permissions"
if (-not $DryRun) {
    $protect = Protect-GwmDataDirs -Root $dataRoot
    if (-not $protect.Safe -or -not $protect.OwnerFixed) {
        foreach ($o in @((Test-GwmPathAcl -Path $dataRoot -Recurse).Offenders)) {
            Write-Host ('[fail] {0} ({1}) on {2}' -f $o.Identity, $o.Rights, $o.Path)
        }
        Stop-Install ("the data folders under $dataRoot are not locked down (Safe: {0}, OwnerFixed: {1}); fix them and run this installer again" -f $protect.Safe, $protect.OwnerFixed)
    }
    $changes += 'locked the runtime data folders'
}

# 1. WAU itself.
$msiArgs = New-GwmWauMsiArguments
$override = '/qn /norestart ' + $msiArgs
$plannedWauDir = $wauDir
if ($null -eq $plannedWauDir) {
    # Default of the WAU MSI (INSTALLDIR under ProgramFiles6432Folder).
    $plannedWauDir = Join-Path $env:ProgramFiles 'Winget-AutoUpdate'
}
if ($null -ne $wauDir) {
    Write-Step "WAU is already installed at $wauDir; skip winget install"
}
else {
    Write-Step "winget install --id $wauId --exact --silent --accept-package-agreements --accept-source-agreements --override `"$override`""
}

if (-not $DryRun) {
    if ($null -eq $wauDir) {
        & winget install --id $wauId --exact --silent --accept-package-agreements --accept-source-agreements --override $override
        if ($LASTEXITCODE -ne 0) { Stop-Install "winget install failed with exit code $LASTEXITCODE" }
        $wauDir = Get-GwmWauInstallDir
        if ($null -eq $wauDir) { Stop-Install 'WAU was installed but its folder was not found in the registry' }
        $changes += "installed $wauId"
    }
    $plannedWauDir = $wauDir
    # Whitelist mode is a property of the MSI; an older install may have been made without it.
    $config = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate' -ErrorAction SilentlyContinue
    if ($null -eq $config -or $null -eq $config.PSObject.Properties['WAU_UseWhiteList'] -or [int]$config.WAU_UseWhiteList -ne 1) {
        Stop-Install 'WAU is installed without whitelist mode (WAU_UseWhiteList is not 1); uninstall WAU and run this installer again'
    }
}

$modsDir = Join-Path $plannedWauDir 'mods'
$gwmDir = Join-Path $modsDir 'gwm'
$listPath = Join-Path $plannedWauDir 'included_apps.txt'
$contextPath = Join-Path $gwmDir 'context.json'
$recordPath = Join-Path $gwmDir 'installed-files.json'

# 2. Whitelist.
$whitelistIds = @(Get-GwmWhitelist -Manifest $manifest)
Write-Step ("write the whitelist ($($whitelistIds.Count) ids) to $listPath")
if (-not $DryRun) {
    [System.IO.File]::WriteAllText($listPath, (ConvertTo-GwmWhitelistText -Manifest $manifest), [System.Text.Encoding]::ASCII)
    $files += $listPath
    $changes += 'wrote the whitelist'
}

# 3. Runtime and thin mods.
Write-Step "copy the runtime (lib, tasks, apps.psd1, _WAU-mods.ps1) into $modsDir"
Write-Step "generate the thin per-app mods in $modsDir"
if (-not $DryRun) {
    $files += @(Copy-GwmRuntime -RepoRoot $repoRoot -WauDir $wauDir)
    $files += @(Write-GwmThinMods -Manifest $manifest -ModsDir $modsDir)
    $changes += 'copied the runtime and wrote the thin mods'
}

# 4. User context.
Write-Step "record the desktop user (SID and profile folder) in $contextPath"
if (-not $DryRun) {
    Save-GwmUserContext -Path $contextPath -UserSid $user.UserSid -ProfilePath $user.ProfilePath
    $files += $contextPath
    $changes += 'saved the user context'
}

# 5. Scheduled tasks.
foreach ($app in $taskApps) {
    Write-Step ("register tasks '{0}-close' and '{0}-open' in {1}" -f $app.Process, $manifest.TaskFolder)
}
if (-not $DryRun) {
    $context = Get-GwmUserContext -Path $contextPath
    $null = Register-GwmTasks -Apps $taskApps -UserSid $user.UserSid -TasksDir (Join-Path $gwmDir 'tasks') -TaskFolder $manifest.TaskFolder -UserContext $context
    $changes += 'registered the scheduled tasks'
}

# 6. Record of what this installer created, for the uninstaller.
Write-Step "record the created files in $recordPath"
if (-not $DryRun) {
    $previous = @()
    if (Test-Path -LiteralPath $recordPath -PathType Leaf) {
        try {
            $old = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
            if ($null -ne $old -and $null -ne $old.PSObject.Properties['Files']) { $previous = @($old.Files) }
        }
        catch {
            Write-Host '[warn] the previous installed-files.json is unreadable and was replaced'
        }
    }
    $all = @(($previous + $files) | Where-Object { $_ } | Sort-Object -Unique)
    $json = [pscustomobject]@{ SchemaVersion = 1; WauDir = $wauDir; Files = $all } | ConvertTo-Json
    [System.IO.File]::WriteAllText($recordPath, $json, [System.Text.Encoding]::ASCII)
}

# 7. Permissions of what SYSTEM will run.
Write-Step "check that no non-admin principal can write to $plannedWauDir or $modsDir (read-only check, nothing is changed)"
if (-not $DryRun) {
    $unsafe = @()
    foreach ($check in @((Test-GwmPathAcl -Path $wauDir), (Test-GwmPathAcl -Path $modsDir -Recurse))) {
        if (-not $check.Safe) { $unsafe += @($check.Offenders) }
    }
    if ($unsafe.Count -gt 0) {
        foreach ($o in $unsafe) {
            Write-Host ('[fail] writable by {0} ({1}) on {2}' -f $o.Identity, $o.Rights, $o.Path)
        }
        Stop-Install 'WAU runs these files as SYSTEM and the permissions above let a non-admin change them; fix the permissions, then run this installer again'
    }
}

# 8. qBittorrent ExitConfirm.
if (@($manifest.Apps | Where-Object { $_.Process -eq 'qbittorrent' }).Count -gt 0) {
    if ($DryRun) {
        Write-Step "check the qBittorrent 'confirm on exit' setting of the desktop user (the settings file is not read in a dry run)"
    }
    else {
        $ini = Expand-GwmPath -Path '%APPDATA%\qBittorrent\qBittorrent.ini' -UserContext $context
        $exit = Test-GwmQbtExitConfirm -IniPath $ini
        if ($exit.ExitConfirm) {
            Write-Host "[warn] qBittorrent asks for confirmation on exit (source: $($exit.Source)); its close request may be answered by a dialog and the update will wait for the next logon. Turn off Tools > Options > Behavior > Confirm when exiting."
        }
    }
}

Write-Host ''
if ($DryRun) {
    Write-Host 'Dry run finished. Nothing was changed.'
}
else {
    Write-Host 'Installed. Changes:'
    foreach ($c in $changes) { Write-Host ('  - ' + $c) }
    Write-Host ('  - files recorded: ' + (@($files).Count))
}
exit 0
