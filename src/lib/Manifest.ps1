# Manifest loading and path helpers shared by every slice.
# The manifest is read with Import-PowerShellDataFile, so it can hold data only.

function Import-GwmManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    # Kept local: a $script: table would be empty when the caller is another script file.
    $scopes = @('machine', 'user')
    $policies = @('close-reopen', 'skip-if-open')

    $manifest = Import-PowerShellDataFile -LiteralPath $Path
    if ($null -eq $manifest.Apps) {
        $manifest.Apps = @()
    }

    $seen = @{}
    foreach ($app in @($manifest.Apps)) {
        foreach ($key in 'Id', 'Process', 'Scope', 'Policy') {
            if (-not $app.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$app[$key])) {
                throw "Manifest app is missing '$key'"
            }
        }
        if ($scopes -notcontains $app.Scope) {
            throw "Unknown Scope '$($app.Scope)' for $($app.Id)"
        }
        if ($policies -notcontains $app.Policy) {
            throw "Unknown Policy '$($app.Policy)' for $($app.Id)"
        }
        if ($app.Policy -eq 'close-reopen') {
            $candidates = @()
            if ($app.ContainsKey('Exe')) {
                $candidates = @($app.Exe | Where-Object { $_ })
            }
            if ($candidates.Count -eq 0) {
                throw "close-reopen app $($app.Id) needs Exe"
            }
        }
        if ($app.ContainsKey('HiddenWindowClass')) {
            $patterns = @($app.HiddenWindowClass | Where-Object { $_ -is [string] -and -not [string]::IsNullOrWhiteSpace($_) })
            if ($patterns.Count -eq 0 -or $patterns.Count -ne @($app.HiddenWindowClass).Count) {
                throw "HiddenWindowClass of $($app.Id) must be a list of non-blank class name patterns"
            }
        }
        $idKey = ([string]$app.Id).ToLowerInvariant()
        if ($seen.ContainsKey($idKey)) {
            throw "Duplicate app id $($app.Id)"
        }
        $seen[$idKey] = $true
    }

    $manifest
}

function Get-GwmApp {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$Id
    )

    foreach ($app in @($Manifest.Apps)) {
        if ($app.Id -eq $Id) {
            return $app
        }
    }
    return $null
}

function Get-GwmWhitelist {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest
    )

    $ids = @()
    foreach ($app in @($Manifest.Apps)) {
        $ids += $app.Id
    }
    foreach ($id in @($Manifest.DefaultApps)) {
        if ($id) { $ids += $id }
    }
    if ($Manifest.SelfId) {
        $ids += $Manifest.SelfId
    }

    $ids | Sort-Object -Unique
}

function Expand-GwmPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        $UserContext
    )

    $expanded = $Path
    if ($null -ne $UserContext -and $UserContext.ProfilePath) {
        # Running as SYSTEM, the per-user folders must point at the real user's profile.
        $userProfile = ([string]$UserContext.ProfilePath).Replace('$', '$$')
        $expanded = $expanded -replace '(?i)%APPDATA%', ($userProfile + '\AppData\Roaming')
        $expanded = $expanded -replace '(?i)%LOCALAPPDATA%', ($userProfile + '\AppData\Local')
        $expanded = $expanded -replace '(?i)%USERPROFILE%', $userProfile
    }

    [Environment]::ExpandEnvironmentVariables($expanded)
}

function Resolve-GwmExe {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$App,
        $UserContext
    )

    if (-not $App.ContainsKey('Exe')) {
        return $null
    }
    foreach ($candidate in @($App.Exe)) {
        $path = Expand-GwmPath -Path $candidate -UserContext $UserContext
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            return $path
        }
    }
    return $null
}

function Save-GwmUserContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$ProfilePath
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $json = [pscustomobject]@{ UserSid = $UserSid; ProfilePath = $ProfilePath } | ConvertTo-Json
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Get-GwmUserContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $context = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        Write-GwmLog "User context file is unreadable: $Path"
        return $null
    }
    if ($null -eq $context -or -not $context.UserSid -or -not $context.ProfilePath) {
        return $null
    }
    $context
}
