# Installer-side helpers for wau-graceful-mods. Dot-sourced by the install scripts and the tests.
# Defines functions only; nothing runs at load time.

function New-GwmWauMsiArguments {
    [CmdletBinding()]
    param(
        [hashtable]$Options = @{}
    )

    # Property names and accepted values come from Sources/Wix/build.wxs in the WAU repository.
    $defaults = [ordered]@{
        UPDATESATLOGON       = '1'
        UPDATESINTERVAL      = 'Never'
        USERCONTEXT          = '1'
        USEWHITELIST         = '1'
        NOTIFICATIONLEVEL    = 'Full'
        DISABLEWAUAUTOUPDATE = '1'
    }

    $merged = [ordered]@{}
    foreach ($name in $defaults.Keys) {
        $merged[$name] = [string]$defaults[$name]
    }

    $extra = @()
    foreach ($key in $Options.Keys) {
        $name = [string]$key
        if ($name -cnotmatch '^[A-Z][A-Z0-9_]*$') {
            throw "Not an MSI property name: '$name'"
        }
        if ($merged.Contains($name)) {
            $merged[$name] = [string]$Options[$key]
        }
        else {
            $extra += $name
        }
    }
    foreach ($name in ($extra | Sort-Object)) {
        $merged[$name] = [string]$Options[$name]
    }

    $parts = @()
    foreach ($name in $merged.Keys) {
        $value = $merged[$name]
        # The result goes into a command line: refuse anything that could split or quote it.
        if ($value -notmatch '^[A-Za-z0-9_.:-]+$') {
            throw "Value of $name is not a plain token: '$value'"
        }
        $parts += ('{0}={1}' -f $name, $value)
    }
    $parts -join ' '
}

function ConvertTo-GwmWhitelistText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest
    )

    $text = ''
    foreach ($id in @(Get-GwmWhitelist -Manifest $Manifest)) {
        $text += $id + "`r`n"
    }
    $text
}

function New-GwmThinModContent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)][ValidateSet('preinstall', 'installed', 'notinstalled')][string]$Kind
    )

    $id = [string]$App.Id
    # The id lands inside a single-quoted literal of a script that WAU runs as SYSTEM.
    if ($id -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._+-]*$') {
        throw "App Id is not a plain winget id: '$id'"
    }

    $load = '. "$PSScriptRoot\gwm\lib\Load.ps1"'
    switch ($Kind) {
        'preinstall' {
            $call = "Invoke-GwmPreInstall -AppId '$id' -InstalledVersion `$app.Version -AvailableVersion `$app.AvailableVersion"
        }
        'installed' {
            $call = "Invoke-GwmPostInstall -AppId '$id' -Succeeded `$true"
        }
        'notinstalled' {
            $call = "Invoke-GwmPostInstall -AppId '$id' -Succeeded `$false"
        }
    }
    $load + "`r`n" + $call + "`r`n"
}

function Write-GwmThinMods {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)][string]$ModsDir
    )

    if (-not (Test-Path -LiteralPath $ModsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $ModsDir -Force | Out-Null
    }

    $written = @()
    foreach ($app in @($Manifest.Apps)) {
        $kinds = @('preinstall')
        if ($app.Policy -eq 'close-reopen') {
            $kinds = @('preinstall', 'installed', 'notinstalled')
        }
        foreach ($kind in $kinds) {
            $path = Join-Path $ModsDir ('{0}-{1}.ps1' -f $app.Id, $kind)
            $content = New-GwmThinModContent -App $app -Kind $kind
            [System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::ASCII)
            $written += $path
        }
    }
    [string[]]$written
}

function Test-GwmElevated {
    [CmdletBinding()]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-GwmAccessControl {
    # Reads the DACL (and optionally the owner) with .NET. Get-Acl also asks for the audit
    # section and fails with "Access is denied" on a folder this account has been locked out of.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$WithOwner
    )

    $sections = [System.Security.AccessControl.AccessControlSections]::Access
    if ($WithOwner) {
        $sections = $sections -bor [System.Security.AccessControl.AccessControlSections]::Owner
    }
    try {
        return [System.IO.Directory]::GetAccessControl($Path, $sections)
    }
    catch [System.IO.DirectoryNotFoundException] {
        return [System.IO.File]::GetAccessControl($Path, $sections)
    }
}

function Set-GwmAccessControl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Security
    )

    if ($Security -is [System.Security.AccessControl.DirectorySecurity]) {
        [System.IO.Directory]::SetAccessControl($Path, $Security)
    }
    else {
        [System.IO.File]::SetAccessControl($Path, $Security)
    }
}

function Test-GwmPathAcl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$Recurse
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        # A folder this account is locked out of reads as missing; the ACL tells the difference.
        try { $null = Get-GwmAccessControl -Path $Path }
        catch { throw "Path does not exist: $Path" }
    }

    # SYSTEM, Administrators, TrustedInstaller, CREATOR OWNER.
    $trusted = @(
        'S-1-5-18',
        'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464',
        'S-1-3-0'
    )
    # Plain integers: GENERIC_* bits are not valid FileSystemRights enum values. FullControl and
    # Modify are not in the masks: they contain read bits, but they also contain every bit below.
    $R = [System.Security.AccessControl.FileSystemRights]
    $genericAll = 0x10000000
    $genericWrite = 0x40000000
    $contentMask = [int]$R::WriteData -bor [int]$R::AppendData -bor [int]$R::WriteExtendedAttributes -bor
        [int]$R::WriteAttributes -bor [int]$R::Delete -bor [int]$R::DeleteSubdirectoriesAndFiles -bor
        [int]$R::ChangePermissions -bor [int]$R::TakeOwnership -bor $genericAll -bor $genericWrite
    $ancestorMask = [int]$R::Delete -bor [int]$R::DeleteSubdirectoriesAndFiles -bor [int]$R::ChangePermissions -bor
        [int]$R::TakeOwnership -bor $genericAll

    $offenders = @()
    $inspect = {
        param([string]$ItemPath, [string]$Scope, $Mask, [bool]$SkipInheritOnly)

        $found = @()
        try {
            $acl = Get-GwmAccessControl -Path $ItemPath
            $rules = $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])
        }
        catch {
            # An ACL that cannot be read cannot be called safe.
            return @([pscustomobject]@{ Path = $ItemPath; Identity = '(unreadable)'; Rights = 'unreadable'; Scope = $Scope })
        }
        foreach ($rule in $rules) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
            $sid = $rule.IdentityReference.Value
            if ($trusted -contains $sid) { continue }
            if ($SkipInheritOnly -and ($rule.PropagationFlags -band [System.Security.AccessControl.PropagationFlags]::InheritOnly)) { continue }
            if (([int]$rule.FileSystemRights -band $Mask) -ne 0) {
                $found += [pscustomobject]@{
                    Path     = $ItemPath
                    Identity = $sid
                    Rights   = [string]$rule.FileSystemRights
                    Scope    = $Scope
                }
            }
        }
        $found
    }

    $target = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($target.Length -eq 2) { $target += '\' }

    $offenders += @(& $inspect $target 'target' $contentMask $false)

    if ($Recurse) {
        $enumErrors = $null
        $children = @(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable enumErrors)
        foreach ($child in $children) {
            $offenders += @(& $inspect $child.FullName 'target' $contentMask $false)
        }
        # Content that cannot be listed cannot be called safe.
        foreach ($err in @($enumErrors)) {
            if ($null -ne $err -and $err.TargetObject) {
                $offenders += [pscustomobject]@{ Path = [string]$err.TargetObject; Identity = '(unreadable)'; Rights = 'unreadable'; Scope = 'target' }
            }
        }
    }

    $parent = [System.IO.Directory]::GetParent($target)
    while ($null -ne $parent) {
        $offenders += @(& $inspect $parent.FullName 'ancestor' $ancestorMask $true)
        $parent = $parent.Parent
    }

    $offenders = @($offenders | Where-Object { $null -ne $_ })
    [pscustomobject]@{
        Path      = $target
        Safe      = ($offenders.Count -eq 0)
        Offenders = [object[]]$offenders
    }
}

function Test-GwmQbtExitConfirm {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$IniPath
    )

    $value = $null
    if (Test-Path -LiteralPath $IniPath -PathType Leaf) {
        $inPreferences = $false
        foreach ($line in @(Get-Content -LiteralPath $IniPath)) {
            $text = ([string]$line).Trim()
            if ($text -match '^\[(.*)\]$') {
                $inPreferences = ($Matches[1] -ieq 'Preferences')
                continue
            }
            if ($inPreferences -and $text -match '^General\\ExitConfirm\s*=\s*(.*)$') {
                $candidate = $Matches[1].Trim()
                if ($candidate -ieq 'true' -or $candidate -ieq 'false') {
                    $value = ($candidate -ieq 'true')
                }
            }
        }
    }

    if ($null -eq $value) {
        return [pscustomobject]@{ Found = $false; ExitConfirm = $true; Source = 'default' }
    }
    [pscustomobject]@{ Found = $true; ExitConfirm = [bool]$value; Source = 'ini' }
}

function Get-GwmWauInstallDir {
    [CmdletBinding()]
    param()

    # WAU's MSI writes InstallLocation under this key.
    $keys = @(
        'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate',
        'HKLM:\SOFTWARE\WOW6432Node\Romanitho\Winget-AutoUpdate'
    )
    foreach ($key in $keys) {
        $item = Get-ItemProperty -LiteralPath $key -Name InstallLocation -ErrorAction SilentlyContinue
        if ($null -eq $item -or $null -eq $item.PSObject.Properties['InstallLocation']) { continue }
        $dir = ([string]$item.InstallLocation).Trim().TrimEnd('\')
        if ($dir -and (Test-Path -LiteralPath $dir -PathType Container)) {
            return $dir
        }
    }
    return $null
}

function Get-GwmInteractiveUser {
    [CmdletBinding()]
    param()

    $explorers = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction SilentlyContinue)
    if ($explorers.Count -eq 0) {
        return $null
    }

    # Prefer the explorer of this session, then the lowest session id.
    $mySession = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    $chosen = @($explorers | Where-Object { $_.SessionId -eq $mySession })
    if ($chosen.Count -eq 0) {
        $chosen = @($explorers | Sort-Object SessionId)
    }

    $owner = Invoke-CimMethod -InputObject $chosen[0] -MethodName GetOwnerSid -ErrorAction SilentlyContinue
    if ($null -eq $owner -or -not $owner.Sid) {
        return $null
    }
    $sid = [string]$owner.Sid

    $profilePath = $null
    $profile = Get-ItemProperty -LiteralPath ('HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sid) -Name ProfileImagePath -ErrorAction SilentlyContinue
    if ($null -ne $profile -and $null -ne $profile.PSObject.Properties['ProfileImagePath']) {
        $profilePath = [Environment]::ExpandEnvironmentVariables([string]$profile.ProfileImagePath)
    }
    if (-not $profilePath) {
        return $null
    }

    $name = $sid
    try {
        $name = (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        Write-GwmLog "Could not translate $sid to an account name"
    }

    [pscustomobject]@{ UserSid = $sid; ProfilePath = $profilePath; Name = $name }
}

function Copy-GwmRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$WauDir
    )

    $modsDir = Join-Path $WauDir 'mods'
    $gwmDir = Join-Path $modsDir 'gwm'

    # Source -> destination, checked in full before anything is copied.
    $plan = @()
    $plan += , @((Join-Path $RepoRoot 'src\mods\_WAU-mods.ps1'), (Join-Path $modsDir '_WAU-mods.ps1'))
    $plan += , @((Join-Path $RepoRoot 'config\apps.psd1'), (Join-Path $gwmDir 'apps.psd1'))
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'src\lib') -Filter '*.ps1' -File | Sort-Object Name)) {
        $plan += , @($file.FullName, (Join-Path $gwmDir ('lib\' + $file.Name)))
    }
    foreach ($name in 'Invoke-CloseTask.ps1', 'Invoke-OpenTask.ps1') {
        $plan += , @((Join-Path $RepoRoot ('src\tasks\' + $name)), (Join-Path $gwmDir ('tasks\' + $name)))
    }
    $plan += , @((Join-Path $RepoRoot 'src\lib\Load.ps1'), (Join-Path $gwmDir 'lib\Load.ps1'))

    foreach ($entry in $plan) {
        if (-not (Test-Path -LiteralPath $entry[0] -PathType Leaf)) {
            throw "Runtime file missing in the repository: $($entry[0])"
        }
    }

    $copied = @()
    foreach ($entry in $plan) {
        $destination = $entry[1]
        if ($copied -contains $destination) { continue }
        $destDir = Split-Path -Parent $destination
        if (-not (Test-Path -LiteralPath $destDir -PathType Container)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $entry[0] -Destination $destination -Force
        $copied += $destination
    }
    [string[]]$copied
}

function Assert-GwmNotReparsePoint {
    # Set-Acl follows a junction or symlink and would re-ACL its target, so refuse one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        throw "Refusing a reparse point (junction or symlink): $Path"
    }
}

function Get-GwmTreePaths {
    # Every path below $Path, deepest last. Never follows a reparse point: it throws on one.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) {
        Assert-GwmNotReparsePoint -Path $child.FullName
        $child.FullName
        if ($child.PSIsContainer) {
            Get-GwmTreePaths -Path $child.FullName
        }
    }
}

function Protect-GwmDataDirs {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root
    )

    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\')
    $statePath = Join-Path $rootPath 'state'
    $backupsPath = Join-Path $rootPath 'backups'
    $dirs = @($rootPath, $statePath, $backupsPath)

    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $elevated = Test-GwmElevated
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $none = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl

    # Look before changing anything: nothing existing may be a reparse point.
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath $d) {
            Assert-GwmNotReparsePoint -Path $d
            if (-not (Test-Path -LiteralPath $d -PathType Container)) {
                throw "Not a folder: $d"
            }
        }
    }
    $inside = @()
    if (Test-Path -LiteralPath $rootPath) {
        $inside = @(Get-GwmTreePaths -Path $rootPath | Where-Object { $dirs -notcontains $_ })
    }

    $created = @()
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) {
            New-Item -ItemType Directory -Path $d | Out-Null
            $created += $d
        }
    }

    # Content already in the folders (for example planted by a user): drop its own rules so it
    # inherits the locked folder, deepest first while this account can still reach it.
    foreach ($path in @($inside | Sort-Object { $_.Length } -Descending)) {
        Assert-GwmNotReparsePoint -Path $path
        $acl = Get-GwmAccessControl -Path $path -WithOwner
        $acl.SetAccessRuleProtection($false, $false)
        foreach ($rule in @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]))) {
            $null = $acl.RemoveAccessRuleSpecific($rule)
        }
        if ($elevated) { $acl.SetOwner($adminSid) }
        Set-GwmAccessControl -Path $path -Security $acl
    }

    # The three folders, deepest first so the parent is locked last.
    foreach ($d in @($statePath, $backupsPath, $rootPath)) {
        Assert-GwmNotReparsePoint -Path $d
        $acl = Get-GwmAccessControl -Path $d -WithOwner
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) {
            $null = $acl.RemoveAccessRuleSpecific($rule)
        }
        foreach ($sid in $systemSid, $adminSid) {
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($sid, $full, $inherit, $none, $allow)))
        }
        if ($elevated) { $acl.SetOwner($adminSid) }
        Set-GwmAccessControl -Path $d -Security $acl
    }

    $ownerFixed = $false
    if ($elevated) {
        $ownerFixed = $true
        foreach ($d in $dirs) {
            $owner = (Get-GwmAccessControl -Path $d -WithOwner).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
            if ($owner -ne $adminSid.Value) { $ownerFixed = $false }
        }
    }

    $check = Test-GwmPathAcl -Path $rootPath -Recurse
    [pscustomobject]@{
        Root       = $rootPath
        Created    = [string[]]$created
        OwnerFixed = $ownerFixed
        Safe       = [bool]$check.Safe
    }
}

function Remove-GwmTaskFolderIfEmpty {
    # Deletes one Task Scheduler folder, but only when it holds no task and no subfolder.
    # Returns $true when it deleted the folder, $false when it did nothing.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$TaskFolder
    )

    $path = $TaskFolder.TrimEnd('\')
    if ($path -notmatch '^\\[^\\]') {
        throw "Invalid task folder (must start with '\' and name a folder, never the root): '$TaskFolder'"
    }
    $segments = $path.Substring(1).Split('\')
    foreach ($segment in $segments) {
        if ($segment -eq '' -or $segment -eq '.' -or $segment -eq '..' -or $segment -match '[<>:"/|?*\x00-\x1F]') {
            throw "Invalid task folder segment '$segment' in '$TaskFolder'"
        }
    }

    $service = New-Object -ComObject Schedule.Service
    $service.Connect()

    try {
        $folder = $service.GetFolder($path)
    }
    catch {
        # PowerShell wraps the COM error; look at it and at what it wraps.
        # 0x80070002 file not found, 0x80070003 path not found: nothing to remove.
        $missing = $false
        for ($e = $_.Exception; $null -ne $e; $e = $e.InnerException) {
            if ($e.HResult -eq -2147024894 -or $e.HResult -eq -2147024893) { $missing = $true }
        }
        if ($missing) { return $false }
        throw
    }

    # 1 = include hidden tasks.
    if ($folder.GetTasks(1).Count -gt 0 -or $folder.GetFolders(0).Count -gt 0) {
        Write-GwmLog "Task folder $path is not empty, left in place"
        return $false
    }

    $leaf = $segments[$segments.Count - 1]
    $parentPath = '\'
    if ($segments.Count -gt 1) {
        $parentPath = '\' + ($segments[0..($segments.Count - 2)] -join '\')
    }
    $service.GetFolder($parentPath).DeleteFolder($leaf, 0)
    return $true
}
