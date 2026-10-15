# Policy logic behind the WAU mods: close an app before its update, remember that it owes
# a reopen, reopen it afterwards, and reconcile at logon. Collaborators are looked up by
# name at call time: Close-App, Invoke-GwmTask, Test-GwmInteractiveSession and the
# manifest/marker helpers. Every entry point emits exactly one value of its contract type.

function Get-GwmDefaultManifestPath {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    # $PSScriptRoot is this file's folder (<gwm>\lib), whoever calls the function.
    Join-Path (Split-Path -Parent $PSScriptRoot) 'apps.psd1'
}

function Get-GwmModManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ManifestPath)

    # Checked here because Import-PowerShellDataFile reports a missing file on the error stream.
    if (-not (Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
        throw "Manifest not found: $ManifestPath"
    }
    Import-GwmManifest -Path $ManifestPath
}

function Get-GwmModUserContext {
    [CmdletBinding()]
    param()

    Get-GwmUserContext -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'context.json')
}

function ConvertTo-GwmMajor {
    [CmdletBinding()]
    param([string]$Version)

    # '<7.0' and other non-numeric starts (winget prints these for unknown installs) have no major.
    if ($Version -match '^\s*[vV]?(\d{1,9})') {
        return [int]$Matches[1]
    }
    return $null
}

function Get-GwmExeMajorVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    }
    catch {
        return $null
    }
    if ([string]::IsNullOrEmpty($info.FileVersion)) {
        return $null
    }
    return [int]$info.FileMajorPart
}

function Test-GwmMajorUpgrade {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [string]$InstalledVersion,
        [string]$AvailableVersion,
        $App,
        $UserContext
    )

    $available = ConvertTo-GwmMajor -Version $AvailableVersion
    if ($null -eq $available) {
        Write-GwmLog "Available version '$AvailableVersion' has no major; treating it as a major upgrade"
        return $true
    }

    $installed = ConvertTo-GwmMajor -Version $InstalledVersion
    if ($null -eq $installed -and $null -ne $App) {
        $exe = Resolve-GwmExe -App $App -UserContext $UserContext
        if ($exe) {
            $installed = Get-GwmExeMajorVersion -Path $exe
        }
    }
    if ($null -eq $installed) {
        Write-GwmLog "Installed major of '$InstalledVersion' is unknown; treating it as a major upgrade"
        return $true
    }

    return [bool]($available -gt $installed)
}

function Copy-GwmTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Source,
        [Parameter(Mandatory = $true)][string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force -ErrorAction Stop | Out-Null
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction Stop)) {
        # A junction or symlink inside user-owned data must not make the copy leave that folder.
        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            Write-GwmLog "Backup skips reparse point $($item.FullName)"
            continue
        }
        $target = Join-Path $Destination $item.Name
        if ($item.PSIsContainer) {
            Copy-GwmTree -Source $item.FullName -Destination $target
        }
        else {
            Copy-Item -LiteralPath $item.FullName -Destination $target -Force -ErrorAction Stop
        }
    }
}

function Backup-GwmAppData {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]$App,
        $UserContext,
        [string]$BackupRoot,
        [int]$Keep = 2
    )

    if (-not $App.ContainsKey('BackupOnMajorUpgrade') -or [string]::IsNullOrWhiteSpace([string]$App.BackupOnMajorUpgrade)) {
        throw "App $($App.Id) has no BackupOnMajorUpgrade path"
    }
    $source = Expand-GwmPath -Path $App.BackupOnMajorUpgrade -UserContext $UserContext
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Backup source folder not found: $source"
    }
    $sourceItem = Get-Item -LiteralPath $source -Force
    if (($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Backup source is a reparse point, refusing to copy it: $source"
    }

    if ([string]::IsNullOrWhiteSpace($BackupRoot)) {
        $BackupRoot = Join-Path $env:ProgramData 'wau-graceful-mods\backups'
    }
    if ($Keep -lt 1) { $Keep = 1 }

    $process = [string]$App.Process
    $stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
    $destination = Join-Path $BackupRoot ('{0}-{1}' -f $process, $stamp)
    $suffix = 1
    while (Test-Path -LiteralPath $destination) {
        $suffix++
        $destination = Join-Path $BackupRoot ('{0}-{1}-{2}' -f $process, $stamp, $suffix)
    }

    # Copy beside the final name and rename, so a half copy is never mistaken for a backup.
    $partial = $destination + '.partial'
    try {
        New-Item -ItemType Directory -Path $BackupRoot -Force -ErrorAction Stop | Out-Null
        Copy-GwmTree -Source $source -Destination $partial
        Move-Item -LiteralPath $partial -Destination $destination -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath $partial -Recurse -Force -ErrorAction SilentlyContinue
        throw "Backup of $($App.Id) failed: $($_.Exception.Message)"
    }

    try {
        $pattern = '^{0}-\d{{8}}-\d{{6}}(-\d+)?$' -f [regex]::Escape($process)
        $names = [string[]]@(Get-ChildItem -LiteralPath $BackupRoot -Directory -ErrorAction Stop |
                Where-Object { $_.Name -match $pattern } |
                ForEach-Object { $_.Name })
        [Array]::Sort($names, [System.StringComparer]::Ordinal)
        $excess = $names.Count - $Keep
        for ($i = 0; $i -lt $excess; $i++) {
            Remove-Item -LiteralPath (Join-Path $BackupRoot $names[$i]) -Recurse -Force -ErrorAction Stop
        }
    }
    catch {
        Write-GwmLog "Pruning old backups of $process failed: $($_.Exception.Message)"
    }

    return $destination
}

function Invoke-GwmReopen {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]$App,
        $UserContext,
        [string]$TaskFolder = '\wau-graceful-mods\'
    )

    try {
        if ($App.Scope -eq 'machine') {
            $taskArgs = @{ App = $App; Action = 'open' }
            if ($TaskFolder) { $taskArgs.TaskFolder = $TaskFolder }
            $result = Invoke-GwmTask @taskArgs
            $ok = ($null -ne $result) -and [bool]$result.Completed -and ([int]$result.Result -eq 0)
            if (-not $ok) {
                Write-GwmLog "Reopen task for $($App.Process) did not succeed"
            }
            return [bool]$ok
        }

        if (Test-GwmProcessRunning -ProcessName $App.Process) {
            return $true
        }
        if (Test-GwmRunningAsSystem) {
            # A user-scope exe sits in a user-writable folder; never start it as SYSTEM.
            Write-GwmLog "Not reopening $($App.Process): running as SYSTEM, a user session must do it"
            return $false
        }
        $exe = Resolve-GwmExe -App $App -UserContext $UserContext
        if (-not $exe) {
            Write-GwmLog "Cannot reopen $($App.Process): no executable found"
            return $false
        }
        Start-Process -FilePath $exe | Out-Null
        return $true
    }
    catch {
        Write-GwmLog "Reopen of $($App.Process) failed: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-GwmClose {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]$App,
        [string]$TaskFolder,
        [int]$TimeoutSec = 60
    )

    $exited = $false
    try {
        if ($App.Scope -eq 'machine') {
            # The wrapper in the user session waits $TimeoutSec for the app and decides; the task
            # gets 20 s more for the scheduler start and PowerShell startup so it cannot race it.
            $taskArgs = @{ App = $App; Action = 'close'; TimeoutSec = ($TimeoutSec + 20) }
            if ($TaskFolder) { $taskArgs.TaskFolder = $TaskFolder }
            $result = Invoke-GwmTask @taskArgs
            $exited = ($null -ne $result) -and [bool]$result.Completed -and ([int]$result.Result -eq 0)
        }
        else {
            $closeArgs = @{ ProcessName = $App.Process; TimeoutSec = $TimeoutSec }
            if ($App.ContainsKey('HiddenWindowClass') -and @($App.HiddenWindowClass).Count -gt 0) {
                $closeArgs.HiddenWindowClass = [string[]]@($App.HiddenWindowClass)
            }
            $result = Close-App @closeArgs
            $exited = ($null -ne $result) -and [bool]$result.Exited
        }
    }
    catch {
        Write-GwmLog "Closing $($App.Process) failed: $($_.Exception.Message)"
    }

    # Re-checked now, not cached: a task that reports timeout may still have seen the app go.
    return [bool]($exited -or -not (Test-GwmProcessRunning -ProcessName $App.Process))
}

function Get-GwmTaskFolder {
    [CmdletBinding()]
    param($Manifest)

    if ($Manifest -is [System.Collections.IDictionary] -and $Manifest.Contains('TaskFolder')) {
        return [string]$Manifest['TaskFolder']
    }
    return $null
}

function Invoke-GwmPreInstall {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [string]$InstalledVersion = '',
        [string]$AvailableVersion = '',
        [string]$ManifestPath,
        [int]$TimeoutSec = 60
    )

    try {
        if (-not $ManifestPath) { $ManifestPath = Get-GwmDefaultManifestPath }
        try {
            $manifest = Get-GwmModManifest -ManifestPath $ManifestPath
        }
        catch {
            # Without the manifest nothing is known about the app: leave it alone this run.
            Write-GwmLog "Manifest unreadable, skipping $AppId this run: $($_.Exception.Message)"
            return $false
        }

        $app = Get-GwmApp -Manifest $manifest -Id $AppId
        if ($null -eq $app) {
            return $true
        }

        $running = Test-GwmProcessRunning -ProcessName $app.Process
        if ($app.Policy -eq 'skip-if-open') {
            if ($running) {
                Write-GwmLog "$AppId is open; skipping its update"
            }
            return [bool](-not $running)
        }

        if (-not $running) {
            return $true
        }

        $taskFolder = Get-GwmTaskFolder -Manifest $manifest
        $context = Get-GwmModUserContext

        Set-GwmReopenOwed -ProcessName $app.Process
        if (-not (Invoke-GwmClose -App $app -TaskFolder $taskFolder -TimeoutSec $TimeoutSec)) {
            Clear-GwmReopenOwed -ProcessName $app.Process
            Write-GwmLog "$AppId did not exit; its update waits for the next logon"
            return $false
        }

        $wantsBackup = $app.ContainsKey('BackupOnMajorUpgrade') -and $app.BackupOnMajorUpgrade
        if ($wantsBackup -and (Test-GwmMajorUpgrade -InstalledVersion $InstalledVersion -AvailableVersion $AvailableVersion -App $app -UserContext $context)) {
            try {
                Backup-GwmAppData -App $app -UserContext $context | Out-Null
            }
            catch {
                Write-GwmLog "Backup before the update of $AppId failed, skipping the update: $($_.Exception.Message)"
                if (Invoke-GwmReopen -App $app -UserContext $context -TaskFolder $taskFolder) {
                    Clear-GwmReopenOwed -ProcessName $app.Process
                }
                return $false
            }
        }

        return $true
    }
    catch {
        # Skipping is the safe answer: the marker (if set) lets the next logon reopen the app.
        Write-GwmLog "Pre-install for $AppId failed, skipping the update: $($_.Exception.Message)"
        return $false
    }
}

function Invoke-GwmPostInstall {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$AppId,
        [Parameter(Mandatory = $true)][bool]$Succeeded,
        [string]$ManifestPath
    )

    try {
        if (-not $ManifestPath) { $ManifestPath = Get-GwmDefaultManifestPath }
        $manifest = Get-GwmModManifest -ManifestPath $ManifestPath
        $app = Get-GwmApp -Manifest $manifest -Id $AppId
        if ($null -ne $app -and $app.Policy -eq 'close-reopen') {
            $owed = @(Get-GwmReopenOwed)
            if ($owed -contains $app.Process) {
                Write-GwmLog "Update of $AppId finished (succeeded=$Succeeded); reopening it"
                $context = Get-GwmModUserContext
                if (Invoke-GwmReopen -App $app -UserContext $context -TaskFolder (Get-GwmTaskFolder -Manifest $manifest)) {
                    Clear-GwmReopenOwed -ProcessName $app.Process
                }
            }
        }
    }
    catch {
        Write-GwmLog "Post-install for $AppId failed: $($_.Exception.Message)"
    }

    return $true
}

function Invoke-GwmReconcile {
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$ManifestPath
    )

    $reopened = 0
    try {
        if (-not $ManifestPath) { $ManifestPath = Get-GwmDefaultManifestPath }
        $manifest = Get-GwmModManifest -ManifestPath $ManifestPath
        $taskFolder = Get-GwmTaskFolder -Manifest $manifest
        $context = Get-GwmModUserContext

        foreach ($name in @(Get-GwmReopenOwed)) {
            $app = $null
            foreach ($candidate in @($manifest.Apps)) {
                if ($candidate.Process -eq $name) { $app = $candidate; break }
            }
            if ($null -eq $app -or $app.Policy -ne 'close-reopen') {
                Write-GwmLog "Dropping reopen marker for ${name}: not a close-reopen app in the manifest"
                Clear-GwmReopenOwed -ProcessName $name
                continue
            }
            if (Test-GwmProcessRunning -ProcessName $app.Process) {
                Clear-GwmReopenOwed -ProcessName $name
                continue
            }
            if (Invoke-GwmReopen -App $app -UserContext $context -TaskFolder $taskFolder) {
                Clear-GwmReopenOwed -ProcessName $name
                $reopened++
            }
        }
    }
    catch {
        Write-GwmLog "Reconcile failed: $($_.Exception.Message)"
    }

    return [int]$reopened
}

function Wait-GwmSettle {
    [CmdletBinding()]
    param(
        [string]$ManifestPath,
        [int]$MaxWaitSec = 300,
        [int]$PollSec = 5
    )

    $autostart = @()
    try {
        if (-not $ManifestPath) { $ManifestPath = Get-GwmDefaultManifestPath }
        $manifest = Get-GwmModManifest -ManifestPath $ManifestPath
        $autostart = @(@($manifest.Apps) | Where-Object { $_.ContainsKey('Autostart') -and $_.Autostart -eq $true })
    }
    catch {
        Write-GwmLog "Settle cannot read the manifest, waiting for the shell only: $($_.Exception.Message)"
    }
    if ($PollSec -lt 1) { $PollSec = 1 }

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $missing = New-Object System.Collections.Generic.List[string]
        foreach ($app in $autostart) {
            if (-not (Test-GwmProcessRunning -ProcessName $app.Process)) {
                $missing.Add([string]$app.Process)
            }
        }
        $shell = [bool](Test-GwmInteractiveSession)
        if ($shell -and $missing.Count -eq 0) {
            $settled = $true
            break
        }
        $remainingMs = ($MaxWaitSec * 1000) - $clock.ElapsedMilliseconds
        if ($remainingMs -le 0) {
            $settled = $false
            break
        }
        Start-Sleep -Milliseconds ([int][math]::Max(1, [math]::Min($PollSec * 1000, $remainingMs)))
    }

    if (-not $settled) {
        $why = 'no interactive shell'
        if ($missing.Count -gt 0) { $why = 'missing: ' + ($missing -join ', ') }
        if (-not $shell -and $missing.Count -gt 0) { $why = 'no interactive shell; ' + $why }
        Write-GwmLog "Gave up waiting after ${MaxWaitSec}s ($why)"
    }

    [pscustomobject]@{
        Settled   = [bool]$settled
        WaitedSec = [int][math]::Round($clock.Elapsed.TotalSeconds)
        Missing   = [string[]]$missing.ToArray()
    }
}
