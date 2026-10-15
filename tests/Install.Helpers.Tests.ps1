$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'src\lib\Log.ps1')
. (Join-Path $root 'src\lib\Manifest.ps1')
. (Join-Path $root 'install\Install.Helpers.ps1')

# $env:TEMP can come back in 8.3 form (user~1), which several cmdlets reject; expand it once.
$script:tmp = [System.IO.Path]::GetFullPath($env:TEMP)
$script:tempItems = @()

function New-TempDir {
    $dir = Join-Path $script:tmp ('gwm-inst-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $dir | Out-Null
    $script:tempItems += $dir
    $dir
}

function Get-TestTreePaths {
    # Every path below $Path without following reparse points.
    param([string]$Path)
    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        $child.FullName
        if ($child.PSIsContainer -and -not ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            Get-TestTreePaths -Path $child.FullName
        }
    }
}

function Unlock-TestTree {
    # Protect-GwmDataDirs takes the creator's access away; give it back so cleanup can delete.
    param([string]$Path)
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
        [System.IO.Directory]::Delete($Path)
        return
    }
    if ($item.PSIsContainer) {
        try {
            $acl = [System.IO.Directory]::GetAccessControl($Path, [System.Security.AccessControl.AccessControlSections]::Access)
            $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
            [System.IO.Directory]::SetAccessControl($Path, $acl)
        }
        catch { }
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            Unlock-TestTree -Path $child.FullName
        }
    }
}

function Remove-TempItems {
    foreach ($i in $script:tempItems) {
        try { Unlock-TestTree -Path $i } catch { }
        Remove-Item -LiteralPath $i -Recurse -Force -ErrorAction SilentlyContinue
    }
    $script:tempItems = @()
}

function New-FakeManifest {
    @{
        SelfId      = 'Fake.Self'
        DefaultApps = @('Fake.Default')
        Apps        = @(
            @{ Id = 'Fake.Closer'; Process = 'fakecloser'; Scope = 'machine'; Policy = 'close-reopen'; Exe = @('%ProgramFiles%\Fake\fakecloser.exe') },
            @{ Id = 'Fake.Skipper'; Process = 'fakeskipper'; Scope = 'user'; Policy = 'skip-if-open' }
        )
    }
}

Describe 'New-GwmWauMsiArguments' {
    It 'emits the documented defaults in a stable order' {
        New-GwmWauMsiArguments | Should Be 'UPDATESATLOGON=1 UPDATESINTERVAL=Never USERCONTEXT=1 USEWHITELIST=1 NOTIFICATIONLEVEL=Full DISABLEWAUAUTOUPDATE=1'
    }
    It 'returns exactly one string' {
        @(New-GwmWauMsiArguments).Count | Should Be 1
    }
    It 'lets an override replace a default in place' {
        New-GwmWauMsiArguments -Options @{ NOTIFICATIONLEVEL = 'ErrorsOnly' } |
            Should Be 'UPDATESATLOGON=1 UPDATESINTERVAL=Never USERCONTEXT=1 USEWHITELIST=1 NOTIFICATIONLEVEL=ErrorsOnly DISABLEWAUAUTOUPDATE=1'
    }
    It 'appends an extra property after the defaults' {
        $s = New-GwmWauMsiArguments -Options @{ MAXLOGFILES = '5' }
        $s.EndsWith(' MAXLOGFILES=5') | Should Be $true
    }
    It 'sorts several extra properties by name' {
        $s = New-GwmWauMsiArguments -Options @{ ZZZ = '1'; AAA = '2' }
        $s.EndsWith(' AAA=2 ZZZ=1') | Should Be $true
    }
    It 'rejects a value that could inject extra msiexec arguments' {
        { New-GwmWauMsiArguments -Options @{ UPDATESINTERVAL = 'Never /x' } } | Should Throw 'UPDATESINTERVAL'
    }
    It 'rejects a property name that is not an MSI property name' {
        { New-GwmWauMsiArguments -Options @{ 'bad key' = '1' } } | Should Throw 'property name'
    }
}

Describe 'ConvertTo-GwmWhitelistText' {
    It 'lists every id once, sorted, one per line, with a trailing newline' {
        $text = ConvertTo-GwmWhitelistText -Manifest (New-FakeManifest)
        $text | Should Be ("Fake.Closer`r`nFake.Default`r`nFake.Self`r`nFake.Skipper`r`n")
    }
    It 'is plain ASCII' {
        $text = ConvertTo-GwmWhitelistText -Manifest (New-FakeManifest)
        ($text -cmatch '^[\x00-\x7F]*$') | Should Be $true
    }
    It 'matches Get-GwmWhitelist for the shipped manifest' {
        $m = Import-GwmManifest -Path (Join-Path $root 'config\apps.psd1')
        $lines = @((ConvertTo-GwmWhitelistText -Manifest $m) -split "`r`n" | Where-Object { $_ })
        (($lines -join '|') -eq ((Get-GwmWhitelist -Manifest $m) -join '|')) | Should Be $true
    }
}

Describe 'New-GwmThinModContent' {
    $closer = @{ Id = 'Fake.Closer'; Process = 'fakecloser'; Scope = 'machine'; Policy = 'close-reopen' }

    It 'builds the preinstall mod' {
        $expected = ". `"`$PSScriptRoot\gwm\lib\Load.ps1`"`r`nInvoke-GwmPreInstall -AppId 'Fake.Closer' -InstalledVersion `$app.Version -AvailableVersion `$app.AvailableVersion`r`n"
        New-GwmThinModContent -App $closer -Kind preinstall | Should Be $expected
    }
    It 'builds the installed mod' {
        $expected = ". `"`$PSScriptRoot\gwm\lib\Load.ps1`"`r`nInvoke-GwmPostInstall -AppId 'Fake.Closer' -Succeeded `$true`r`n"
        New-GwmThinModContent -App $closer -Kind installed | Should Be $expected
    }
    It 'builds the notinstalled mod' {
        $expected = ". `"`$PSScriptRoot\gwm\lib\Load.ps1`"`r`nInvoke-GwmPostInstall -AppId 'Fake.Closer' -Succeeded `$false`r`n"
        New-GwmThinModContent -App $closer -Kind notinstalled | Should Be $expected
    }
    It 'rejects an id that is not a plain winget id' {
        $bad = @{ Id = "x'; calc; '"; Process = 'x'; Scope = 'user'; Policy = 'skip-if-open' }
        { New-GwmThinModContent -App $bad -Kind preinstall } | Should Throw 'Id'
    }
    It 'rejects an unknown kind' {
        { New-GwmThinModContent -App $closer -Kind postinstall } | Should Throw 'Kind'
    }
    It 'is ASCII and carries no user path' {
        foreach ($k in 'preinstall', 'installed', 'notinstalled') {
            $c = New-GwmThinModContent -App $closer -Kind $k
            ($c -cmatch '^[\x00-\x7F]*$') | Should Be $true
            ($c -match '(?i)[A-Z]:\\|\\Users\\') | Should Be $false
        }
    }
}

Describe 'Write-GwmThinMods' {
    AfterEach { Remove-TempItems }

    It 'writes preinstall only for skip-if-open and all three for close-reopen' {
        $dir = New-TempDir
        $written = @(Write-GwmThinMods -Manifest (New-FakeManifest) -ModsDir $dir)
        $names = @($written | ForEach-Object { Split-Path -Leaf $_ } | Sort-Object)
        ($names -join ',') | Should Be 'Fake.Closer-installed.ps1,Fake.Closer-notinstalled.ps1,Fake.Closer-preinstall.ps1,Fake.Skipper-preinstall.ps1'
    }
    It 'returns the full paths of files that exist' {
        $dir = New-TempDir
        $written = @(Write-GwmThinMods -Manifest (New-FakeManifest) -ModsDir $dir)
        foreach ($p in $written) { (Test-Path -LiteralPath $p -PathType Leaf) | Should Be $true }
    }
    It 'creates the mods folder when it is missing' {
        $dir = Join-Path (New-TempDir) 'mods'
        $null = Write-GwmThinMods -Manifest (New-FakeManifest) -ModsDir $dir
        (Test-Path -LiteralPath $dir -PathType Container) | Should Be $true
    }
    It 'writes the exact generated text, ASCII without a BOM' {
        $dir = New-TempDir
        $null = Write-GwmThinMods -Manifest (New-FakeManifest) -ModsDir $dir
        $path = Join-Path $dir 'Fake.Skipper-preinstall.ps1'
        $bytes = [System.IO.File]::ReadAllBytes($path)
        ($bytes[0] -ne 0xEF) | Should Be $true
        [System.Text.Encoding]::ASCII.GetString($bytes) | Should Be (New-GwmThinModContent -App (New-FakeManifest).Apps[1] -Kind preinstall)
    }
    It 'is safe to run twice' {
        $dir = New-TempDir
        $null = Write-GwmThinMods -Manifest (New-FakeManifest) -ModsDir $dir
        $again = @(Write-GwmThinMods -Manifest (New-FakeManifest) -ModsDir $dir)
        $again.Count | Should Be 4
    }
}

$script:usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')

function Grant-Rights {
    param([string]$Path, [string]$Rights, [string]$Inherit = 'ContainerInherit,ObjectInherit')
    $acl = Get-Acl -LiteralPath $Path
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($script:usersSid, $Rights, $Inherit, 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Get-UsersOffenders {
    param($Result)
    @($Result.Offenders | Where-Object { $_.Identity -eq 'S-1-5-32-545' })
}

$script:prodTaskFolder = '\wau-graceful-mods'
function Get-TaskFolderState {
    # Existence and task count of a task folder, read through the Schedule.Service COM object.
    param([string]$Path)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    try {
        $f = $svc.GetFolder($Path)
        'exists:' + $f.GetTasks(1).Count + ':' + $f.GetFolders(0).Count
    }
    catch { 'absent' }
}
$script:prodFolderBefore = Get-TaskFolderState -Path $script:prodTaskFolder

Describe 'Test-GwmElevated' {
    It 'returns a single bool that matches the current token' {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $expected = (New-Object System.Security.Principal.WindowsPrincipal($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        $r = @(Test-GwmElevated)
        $r.Count | Should Be 1
        ($r[0] -is [bool]) | Should Be $true
        $r[0] | Should Be $expected
    }
}

Describe 'Test-GwmPathAcl' {
    AfterEach { Remove-TempItems }

    It 'reports a read-only system location as Safe' {
        $r = Test-GwmPathAcl -Path $env:ProgramFiles
        $r.Safe | Should Be $true
        @($r.Offenders).Count | Should Be 0
    }
    It 'returns the documented shape' {
        $dir = New-TempDir
        $r = Test-GwmPathAcl -Path $dir
        ($r.PSObject.Properties.Name -contains 'Path') | Should Be $true
        ($r.PSObject.Properties.Name -contains 'Safe') | Should Be $true
        ($r.PSObject.Properties.Name -contains 'Offenders') | Should Be $true
        ($r.Safe -is [bool]) | Should Be $true
    }
    It 'does not blame the Users group for a fresh folder' {
        $dir = New-TempDir
        @(Get-UsersOffenders (Test-GwmPathAcl -Path $dir)).Count | Should Be 0
    }
    It 'flags a folder that Users can write to' {
        $dir = New-TempDir
        Grant-Rights -Path $dir -Rights 'Write'
        $r = Test-GwmPathAcl -Path $dir
        $r.Safe | Should Be $false
        $o = @(Get-UsersOffenders $r)
        $o.Count | Should BeGreaterThan 0
        $o[0].Path | Should Be $dir
        $o[0].Scope | Should Be 'target'
    }
    It 'flags write rights that only apply to the folder contents' {
        $dir = New-TempDir
        Grant-Rights -Path $dir -Rights 'Modify' -Inherit 'ContainerInherit,ObjectInherit'
        $acl = Get-Acl -LiteralPath $dir
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($script:usersSid, 'WriteData', 'ObjectInherit', 'InheritOnly', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $dir -AclObject $acl
        @(Get-UsersOffenders (Test-GwmPathAcl -Path $dir)).Count | Should BeGreaterThan 0
    }
    It 'accepts read and execute for Users' {
        $dir = New-TempDir
        Grant-Rights -Path $dir -Rights 'ReadAndExecute'
        @(Get-UsersOffenders (Test-GwmPathAcl -Path $dir)).Count | Should Be 0
    }
    It 'never changes the ACL it inspects' {
        $dir = New-TempDir
        Grant-Rights -Path $dir -Rights 'Write'
        $before = (Get-Acl -LiteralPath $dir).Sddl
        $null = Test-GwmPathAcl -Path $dir
        (Get-Acl -LiteralPath $dir).Sddl | Should Be $before
    }
    It 'flags delete-child rights on an ancestor that applies to the ancestor itself' {
        $parent = New-TempDir
        $child = Join-Path $parent 'child'
        New-Item -ItemType Directory -Path $child | Out-Null
        Grant-Rights -Path $parent -Rights 'DeleteSubdirectoriesAndFiles' -Inherit 'None'
        $r = Test-GwmPathAcl -Path $child
        $o = @(Get-UsersOffenders $r)
        $o.Count | Should Be 1
        $o[0].Path | Should Be $parent
        $o[0].Scope | Should Be 'ancestor'
    }
    It 'ignores plain write rights on an ancestor' {
        $parent = New-TempDir
        $child = Join-Path $parent 'child'
        New-Item -ItemType Directory -Path $child | Out-Null
        Grant-Rights -Path $parent -Rights 'WriteData' -Inherit 'None'
        @(Get-UsersOffenders (Test-GwmPathAcl -Path $child)).Count | Should Be 0
    }
    It 'ignores delete rights on an ancestor that only inherit down' {
        $parent = New-TempDir
        $child = Join-Path $parent 'child'
        New-Item -ItemType Directory -Path $child | Out-Null
        $acl = Get-Acl -LiteralPath $parent
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($script:usersSid, 'Delete', 'ObjectInherit', 'InheritOnly', 'Allow')))
        Set-Acl -LiteralPath $parent -AclObject $acl
        $o = @(Get-UsersOffenders (Test-GwmPathAcl -Path $child) | Where-Object { $_.Scope -eq 'ancestor' })
        $o.Count | Should Be 0
    }
    It 'looks inside the folder only when asked' {
        $parent = New-TempDir
        $child = Join-Path $parent 'inner'
        New-Item -ItemType Directory -Path $child | Out-Null
        Grant-Rights -Path $child -Rights 'Write'
        $acl = Get-Acl -LiteralPath $child
        @(Get-UsersOffenders (Test-GwmPathAcl -Path $parent)).Count | Should Be 0
        $deep = @(Get-UsersOffenders (Test-GwmPathAcl -Path $parent -Recurse))
        $deep.Count | Should BeGreaterThan 0
        $deep[0].Path | Should Be $child
    }
    It 'treats a folder it cannot list as unsafe when asked to look inside' {
        $parent = New-TempDir
        $child = Join-Path $parent 'locked'
        New-Item -ItemType Directory -Path $child | Out-Null
        $sec = [System.IO.Directory]::GetAccessControl($child, [System.Security.AccessControl.AccessControlSections]::Access)
        $sec.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))) { $null = $sec.RemoveAccessRuleSpecific($rule) }
        [System.IO.Directory]::SetAccessControl($child, $sec)
        $r = Test-GwmPathAcl -Path $parent -Recurse
        $r.Safe | Should Be $false
        @($r.Offenders | Where-Object { $_.Identity -eq '(unreadable)' -and $_.Path -eq $child }).Count | Should BeGreaterThan 0
    }
    It 'throws for a path that does not exist' {
        { Test-GwmPathAcl -Path (Join-Path $script:tmp ('gwm-missing-{0}' -f [guid]::NewGuid().ToString('N'))) } | Should Throw
    }
}

Describe 'Protect-GwmDataDirs' {
    AfterEach { Remove-TempItems }

    function New-LocalRootPath {
        # The test owns this folder; it lives under LOCALAPPDATA as the coordinator asked.
        $p = Join-Path ([System.IO.Path]::GetFullPath($env:LOCALAPPDATA)) ('gwm-prot-{0}' -f [guid]::NewGuid().ToString('N'))
        $script:tempItems += $p
        $p
    }
    function Get-ExplicitSids {
        param([string]$Path)
        $acl = Get-GwmAccessControl -Path $Path
        @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]) | ForEach-Object { $_.IdentityReference.Value } | Sort-Object -Unique)
    }
    function Get-TargetOffenders {
        # The user's own profile gives that user full control over every ancestor, so Safe is
        # false under LOCALAPPDATA; what matters here is the folder and its content.
        param([string]$Path)
        # Unelevated, the account that locked the folders cannot list them: those are 'unreadable'.
        @((Test-GwmPathAcl -Path $Path -Recurse).Offenders | Where-Object { $_.Scope -eq 'target' -and $_.Identity -ne '(unreadable)' })
    }

    It 'creates state and backups under a new root and reports them' {
        $root = New-LocalRootPath
        $r = Protect-GwmDataDirs -Root $root
        # Unelevated, the locked folders cannot be listed or stat'ed, but their ACL can be read.
        { $null = Get-GwmAccessControl -Path (Join-Path $root 'state') } | Should Not Throw
        { $null = Get-GwmAccessControl -Path (Join-Path $root 'backups') } | Should Not Throw
        $r.Root | Should Be $root
        (@($r.Created) -contains (Join-Path $root 'state')) | Should Be $true
        (@($r.Created) -contains (Join-Path $root 'backups')) | Should Be $true
        (@($r.Created) -contains $root) | Should Be $true
    }
    It 'returns the documented shape' {
        $r = Protect-GwmDataDirs -Root (New-LocalRootPath)
        foreach ($n in 'Root', 'Created', 'OwnerFixed', 'Safe') { ($r.PSObject.Properties.Name -contains $n) | Should Be $true }
        ($r.OwnerFixed -is [bool]) | Should Be $true
        ($r.Safe -is [bool]) | Should Be $true
    }
    It 'leaves only SYSTEM and Administrators on all three folders, without inheritance' {
        $root = New-LocalRootPath
        $null = Protect-GwmDataDirs -Root $root
        foreach ($p in $root, (Join-Path $root 'state'), (Join-Path $root 'backups')) {
            ((Get-ExplicitSids $p) -join ',') | Should Be 'S-1-5-18,S-1-5-32-544'
            (Get-GwmAccessControl -Path $p).AreAccessRulesProtected | Should Be $true
        }
    }
    It 'passes Test-GwmPathAcl for the folder and everything inside' {
        $root = New-LocalRootPath
        $r = Protect-GwmDataDirs -Root $root
        @(Get-TargetOffenders $root).Count | Should Be 0
        $r.Safe | Should Be ((Test-GwmPathAcl -Path $root -Recurse).Safe)
    }
    It 'sets the owner to Administrators only when elevated' {
        $root = New-LocalRootPath
        $r = Protect-GwmDataDirs -Root $root
        $r.OwnerFixed | Should Be (Test-GwmElevated)
        if (Test-GwmElevated) {
            (Get-GwmAccessControl -Path $root -WithOwner).GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should Be 'S-1-5-32-544'
        }
    }
    It 're-locks a pre-existing folder that Users can write to, including planted content' {
        $root = New-LocalRootPath
        New-Item -ItemType Directory -Path (Join-Path $root 'state') -Force | Out-Null
        Grant-Rights -Path $root -Rights 'Modify'
        Grant-Rights -Path (Join-Path $root 'state') -Rights 'Modify'
        $planted = Join-Path $root 'state\reopen-evil.json'
        Set-Content -LiteralPath $planted -Value '{}'
        $acl = Get-Acl -LiteralPath $planted
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($script:usersSid, 'Modify', 'Allow')))
        Set-Acl -LiteralPath $planted -AclObject $acl
        @(Get-UsersOffenders (Test-GwmPathAcl -Path $root -Recurse)).Count | Should BeGreaterThan 0

        $r = Protect-GwmDataDirs -Root $root
        @(Get-UsersOffenders (Test-GwmPathAcl -Path $root -Recurse)).Count | Should Be 0
        @(Get-TargetOffenders $root).Count | Should Be 0
        ((Get-ExplicitSids $root) -join ',') | Should Be 'S-1-5-18,S-1-5-32-544'
        $planted = Join-Path $root 'state\reopen-evil.json'
        (Get-GwmAccessControl -Path $planted).AreAccessRulesProtected | Should Be $false
        @(Get-ExplicitSids $planted | Where-Object { $_ -eq 'S-1-5-32-545' }).Count | Should Be 0
        (@($r.Created) -contains $root) | Should Be $false
        (@($r.Created) -contains (Join-Path $root 'backups')) | Should Be $true
    }
    It 'is safe to run twice' {
        # Unelevated, the first run takes this account's own access away, so a second run cannot start.
        if (-not (Test-GwmElevated)) { Set-TestInconclusive 'needs an elevated token to re-enter the locked folders'; return }
        $root = New-LocalRootPath
        $null = Protect-GwmDataDirs -Root $root
        $again = Protect-GwmDataDirs -Root $root
        @($again.Created).Count | Should Be 0
        @(Get-TargetOffenders $root).Count | Should Be 0
    }
    foreach ($where in 'state', 'backups') {
        It "refuses a junction at $where and leaves its target alone" {
            $root = New-LocalRootPath
            New-Item -ItemType Directory -Path $root | Out-Null
            $victim = New-TempDir
            $before = (Get-Acl -LiteralPath $victim).Sddl
            $null = & cmd.exe /c mklink /J "$root\$where" "$victim" 2>&1
            (Test-Path -LiteralPath (Join-Path $root $where)) | Should Be $true
            { Protect-GwmDataDirs -Root $root } | Should Throw 'reparse'
            (Get-Acl -LiteralPath $victim).Sddl | Should Be $before
        }
    }
    It 'refuses a junction as the root and leaves its target alone' {
        $victim = New-TempDir
        $before = (Get-Acl -LiteralPath $victim).Sddl
        $root = New-LocalRootPath
        $null = & cmd.exe /c mklink /J "$root" "$victim" 2>&1
        { Protect-GwmDataDirs -Root $root } | Should Throw 'reparse'
        (Get-Acl -LiteralPath $victim).Sddl | Should Be $before
        @(Get-ChildItem -LiteralPath $victim -Force).Count | Should Be 0
    }
    It 'refuses a junction planted inside state' {
        $root = New-LocalRootPath
        New-Item -ItemType Directory -Path (Join-Path $root 'state') -Force | Out-Null
        $victim = New-TempDir
        $before = (Get-Acl -LiteralPath $victim).Sddl
        $null = & cmd.exe /c mklink /J "$root\state\inner" "$victim" 2>&1
        { Protect-GwmDataDirs -Root $root } | Should Throw 'reparse'
        (Get-Acl -LiteralPath $victim).Sddl | Should Be $before
    }
}

Describe 'Remove-GwmTaskFolderIfEmpty' {
    $script:svc = New-Object -ComObject Schedule.Service
    $script:svc.Connect()
    $script:madeFolders = @()

    function New-ThrowawayFolder {
        $name = 'wau-gm-test-{0}' -f [guid]::NewGuid().ToString('N')
        $null = $script:svc.GetFolder('\').CreateFolder($name)
        $script:madeFolders += $name
        $name
    }
    function Test-FolderExists {
        param([string]$Path)
        try { $null = $script:svc.GetFolder($Path); $true } catch { $false }
    }
    function Remove-ThrowawayFolders {
        foreach ($name in $script:madeFolders) {
            try {
                $f = $script:svc.GetFolder('\' + $name)
                foreach ($t in @($f.GetTasks(1))) { $f.DeleteTask($t.Name, 0) }
                $script:svc.GetFolder('\').DeleteFolder($name, 0)
            }
            catch { }
        }
        $script:madeFolders = @()
    }
    function Add-ThrowawayTask {
        param([string]$Name)
        $action = New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\cmd.exe') -Argument '/c exit 0'
        $null = Register-ScheduledTask -TaskPath ('\' + $Name + '\') -TaskName ('gm-test-{0}' -f [guid]::NewGuid().ToString('N')) -Action $action
    }

    AfterEach { Remove-ThrowawayFolders }

    It 'deletes an empty folder and returns one bool' {
        $name = New-ThrowawayFolder
        $r = @(Remove-GwmTaskFolderIfEmpty -TaskFolder ('\' + $name))
        $r.Count | Should Be 1
        $r[0] | Should Be $true
        Test-FolderExists ('\' + $name) | Should Be $false
    }
    It 'accepts the trailing backslash the manifest uses' {
        $name = New-ThrowawayFolder
        Remove-GwmTaskFolderIfEmpty -TaskFolder ('\' + $name + '\') | Should Be $true
        Test-FolderExists ('\' + $name) | Should Be $false
    }
    It 'keeps a folder that still holds a task' {
        $name = New-ThrowawayFolder
        Add-ThrowawayTask -Name $name
        Remove-GwmTaskFolderIfEmpty -TaskFolder ('\' + $name + '\') | Should Be $false
        Test-FolderExists ('\' + $name) | Should Be $true
        @($script:svc.GetFolder('\' + $name).GetTasks(1)).Count | Should Be 1
    }
    It 'keeps a folder that holds a subfolder and deletes only the empty child when asked for it' {
        $name = New-ThrowawayFolder
        $null = $script:svc.GetFolder('\' + $name).CreateFolder('inner')
        Remove-GwmTaskFolderIfEmpty -TaskFolder ('\' + $name) | Should Be $false
        Test-FolderExists ('\' + $name + '\inner') | Should Be $true
        Remove-GwmTaskFolderIfEmpty -TaskFolder ('\' + $name + '\inner') | Should Be $true
        Test-FolderExists ('\' + $name + '\inner') | Should Be $false
        Test-FolderExists ('\' + $name) | Should Be $true
    }
    It 'does nothing and does not fail when the folder does not exist' {
        $missing = '\wau-gm-test-{0}' -f [guid]::NewGuid().ToString('N')
        { Remove-GwmTaskFolderIfEmpty -TaskFolder $missing } | Should Not Throw
        Remove-GwmTaskFolderIfEmpty -TaskFolder $missing | Should Be $false
        Test-FolderExists $missing | Should Be $false
    }
    It 'refuses the root and anything that could leave the given folder' {
        foreach ($bad in '\', '', 'no-leading-backslash', '\..', '\a\..\b', '\.', '\a\\b', '\a*') {
            { Remove-GwmTaskFolderIfEmpty -TaskFolder $bad } | Should Throw 'Invalid task folder'
        }
    }
    It 'never created or touched the production task folder' {
        # Last on purpose: compares with the state read when this file was loaded.
        (Get-TaskFolderState -Path $script:prodTaskFolder) | Should Be $script:prodFolderBefore
    }
}

Describe 'Test-GwmQbtExitConfirm' {
    AfterEach { Remove-TempItems }

    function New-Ini {
        param([string]$Body)
        $p = Join-Path (New-TempDir) 'qBittorrent.ini'
        [System.IO.File]::WriteAllText($p, $Body, [System.Text.Encoding]::ASCII)
        $p
    }

    It 'defaults to true when the key is absent' {
        $r = Test-GwmQbtExitConfirm -IniPath (New-Ini "[Preferences]`r`nGeneral\Locale=en`r`n")
        $r.ExitConfirm | Should Be $true
        $r.Source | Should Be 'default'
        $r.Found | Should Be $false
    }
    It 'defaults to true when the file does not exist' {
        $r = Test-GwmQbtExitConfirm -IniPath (Join-Path $script:tmp ('gwm-missing-{0}.ini' -f [guid]::NewGuid().ToString('N')))
        $r.ExitConfirm | Should Be $true
        $r.Source | Should Be 'default'
    }
    It 'reads an explicit false' {
        $r = Test-GwmQbtExitConfirm -IniPath (New-Ini "[Preferences]`r`nGeneral\ExitConfirm=false`r`n")
        $r.ExitConfirm | Should Be $false
        $r.Source | Should Be 'ini'
        $r.Found | Should Be $true
    }
    It 'reads an explicit true' {
        $r = Test-GwmQbtExitConfirm -IniPath (New-Ini "[Preferences]`r`nGeneral\ExitConfirm=true`r`n")
        $r.ExitConfirm | Should Be $true
        $r.Source | Should Be 'ini'
    }
    It 'ignores the same key in another section' {
        $r = Test-GwmQbtExitConfirm -IniPath (New-Ini "[Other]`r`nGeneral\ExitConfirm=false`r`n[Preferences]`r`nGeneral\Locale=en`r`n")
        $r.ExitConfirm | Should Be $true
        $r.Source | Should Be 'default'
    }
    It 'ignores key case and surrounding spaces' {
        $r = Test-GwmQbtExitConfirm -IniPath (New-Ini "[Preferences]`r`n general\exitconfirm = False `r`n")
        $r.ExitConfirm | Should Be $false
    }
    It 'treats an unreadable value as the default' {
        $r = Test-GwmQbtExitConfirm -IniPath (New-Ini "[Preferences]`r`nGeneral\ExitConfirm=maybe`r`n")
        $r.ExitConfirm | Should Be $true
        $r.Source | Should Be 'default'
    }
}

Describe 'Get-GwmWauInstallDir' {
    AfterEach { Remove-TempItems }

    It 'reads InstallLocation and drops the trailing backslash' {
        $dir = New-TempDir
        Mock Get-ItemProperty { [pscustomobject]@{ InstallLocation = ($dir + '\') } }
        Get-GwmWauInstallDir | Should Be $dir
    }
    It 'returns $null when the recorded folder is gone' {
        $gone = Join-Path $script:tmp ('gwm-missing-{0}' -f [guid]::NewGuid().ToString('N'))
        Mock Get-ItemProperty { [pscustomobject]@{ InstallLocation = ($gone + '\') } }
        Get-GwmWauInstallDir | Should BeNullOrEmpty
    }
    It 'returns $null when WAU left no registry key' {
        Mock Get-ItemProperty { $null }
        Get-GwmWauInstallDir | Should BeNullOrEmpty
    }
    It 'returns $null when the key has no InstallLocation value' {
        Mock Get-ItemProperty { [pscustomobject]@{ ProductVersion = '1.0' } }
        Get-GwmWauInstallDir | Should BeNullOrEmpty
    }
    It 'asks the 64-bit key first' {
        $dir = New-TempDir
        Mock Get-ItemProperty { [pscustomobject]@{ InstallLocation = $dir } }
        $null = Get-GwmWauInstallDir
        Assert-MockCalled Get-ItemProperty -Times 1 -ParameterFilter { $LiteralPath -eq 'HKLM:\SOFTWARE\Romanitho\Winget-AutoUpdate' }
    }
}

Describe 'Get-GwmInteractiveUser' {
    It 'returns the owner of explorer.exe with a SID and an existing profile' {
        $explorer = @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq [System.Diagnostics.Process]::GetCurrentProcess().SessionId })
        $u = Get-GwmInteractiveUser
        if ($explorer.Count -eq 0) {
            $u | Should BeNullOrEmpty
        }
        else {
            $u.UserSid | Should Match '^S-1-5-21-'
            (Test-Path -LiteralPath $u.ProfilePath -PathType Container) | Should Be $true
            [string]::IsNullOrWhiteSpace($u.Name) | Should Be $false
            $u.UserSid | Should Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        }
    }
}

Describe 'Copy-GwmRuntime' {
    AfterEach { Remove-TempItems }

    function New-FakeRepo {
        param([switch]$WithoutGlobalMod, [switch]$WithoutOpenTask)
        $repo = New-TempDir
        foreach ($d in 'src\lib', 'src\tasks', 'src\mods', 'config', 'install', 'tests') {
            New-Item -ItemType Directory -Path (Join-Path $repo $d) -Force | Out-Null
        }
        foreach ($f in 'Load.ps1', 'Log.ps1', 'Manifest.ps1') { Set-Content -LiteralPath (Join-Path $repo "src\lib\$f") -Value "# $f" }
        Set-Content -LiteralPath (Join-Path $repo 'src\lib\notes.txt') -Value 'not code'
        Set-Content -LiteralPath (Join-Path $repo 'src\tasks\Invoke-CloseTask.ps1') -Value '# close'
        if (-not $WithoutOpenTask) { Set-Content -LiteralPath (Join-Path $repo 'src\tasks\Invoke-OpenTask.ps1') -Value '# open' }
        if (-not $WithoutGlobalMod) { Set-Content -LiteralPath (Join-Path $repo 'src\mods\_WAU-mods.ps1') -Value '# global' }
        Set-Content -LiteralPath (Join-Path $repo 'config\apps.psd1') -Value '@{}'
        Set-Content -LiteralPath (Join-Path $repo 'install\Install.Helpers.ps1') -Value '# installer only'
        $repo
    }

    It 'lays the runtime out as in the contract' {
        $repo = New-FakeRepo
        $wau = New-TempDir
        $copied = @(Copy-GwmRuntime -RepoRoot $repo -WauDir $wau)
        $rel = @($copied | ForEach-Object { $_.Substring($wau.Length).TrimStart('\') } | Sort-Object)
        ($rel -join '|') | Should Be ((@(
            'mods\_WAU-mods.ps1',
            'mods\gwm\apps.psd1',
            'mods\gwm\lib\Load.ps1',
            'mods\gwm\lib\Log.ps1',
            'mods\gwm\lib\Manifest.ps1',
            'mods\gwm\tasks\Invoke-CloseTask.ps1',
            'mods\gwm\tasks\Invoke-OpenTask.ps1'
        ) | Sort-Object) -join '|')
        foreach ($p in $copied) { (Test-Path -LiteralPath $p -PathType Leaf) | Should Be $true }
    }
    It 'copies file contents and leaves installer and non-script files behind' {
        $repo = New-FakeRepo
        $wau = New-TempDir
        $null = Copy-GwmRuntime -RepoRoot $repo -WauDir $wau
        (Get-Content -LiteralPath (Join-Path $wau 'mods\gwm\lib\Log.ps1') -Raw).Trim() | Should Be '# Log.ps1'
        (Test-Path -LiteralPath (Join-Path $wau 'mods\gwm\lib\notes.txt')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $wau 'mods\gwm\install')) | Should Be $false
    }
    It 'overwrites an older copy when run again' {
        $repo = New-FakeRepo
        $wau = New-TempDir
        $null = Copy-GwmRuntime -RepoRoot $repo -WauDir $wau
        Set-Content -LiteralPath (Join-Path $repo 'src\lib\Log.ps1') -Value '# changed'
        $null = Copy-GwmRuntime -RepoRoot $repo -WauDir $wau
        (Get-Content -LiteralPath (Join-Path $wau 'mods\gwm\lib\Log.ps1') -Raw).Trim() | Should Be '# changed'
    }
    It 'refuses a repository without the global mod and copies nothing' {
        $repo = New-FakeRepo -WithoutGlobalMod
        $wau = New-TempDir
        { Copy-GwmRuntime -RepoRoot $repo -WauDir $wau } | Should Throw '_WAU-mods.ps1'
        @(Get-ChildItem -LiteralPath $wau -Force).Count | Should Be 0
    }
    It 'refuses a repository without the open task wrapper' {
        $repo = New-FakeRepo -WithoutOpenTask
        $wau = New-TempDir
        { Copy-GwmRuntime -RepoRoot $repo -WauDir $wau } | Should Throw 'Invoke-OpenTask.ps1'
    }
}

function Get-ShellState {
    # Everything a real run could touch: this repository copy, the runtime state folder, the WAU
    # folder (installed or default) and the scheduled tasks.
    $parts = @()
    $wau = Get-GwmWauInstallDir
    if (-not $wau) { $wau = Join-Path $env:ProgramFiles 'Winget-AutoUpdate' }
    $state = Join-Path $env:ProgramData 'wau-graceful-mods'
    foreach ($dir in $root, $wau, $state) {
        if (Test-Path -LiteralPath $dir) {
            $parts += (Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue |
                Sort-Object FullName | ForEach-Object {
                    # A folder has no Length property: reading it is an error under strict mode.
                    $size = 0
                    if (-not $_.PSIsContainer) { $size = $_.Length }
                    '{0}|{1}|{2}' -f $_.FullName, $size, $_.LastWriteTimeUtc.Ticks
                })
        }
        else {
            $parts += "absent:$dir"
        }
    }
    # Only the folders a real run would use: other test runs create tasks in throwaway folders.
    foreach ($folder in '\wau-graceful-mods\', '\WAU\') {
        $parts += (Get-ScheduledTask -TaskPath $folder -ErrorAction SilentlyContinue | Sort-Object TaskName | ForEach-Object { $_.TaskPath + $_.TaskName + '|' + $_.State })
    }
    $parts -join "`n"
}

function Invoke-InstallScript {
    param([string]$Name, [string[]]$Arguments)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $out = & $ps -NoProfile -NonInteractive -ExecutionPolicy Bypass -File (Join-Path $root "install\$Name") @Arguments 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}

Describe 'install scripts' {
    foreach ($name in 'Install-WauGracefulMods.ps1', 'Uninstall-WauGracefulMods.ps1', 'Install.Helpers.ps1') {
        It "$name parses and is ASCII" {
            $path = Join-Path $root "install\$name"
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
            @($errors).Count | Should Be 0
            ([System.IO.File]::ReadAllText($path) -cmatch '^[\x00-\x7F]*$') | Should Be $true
        }
    }

    Context 'Install-WauGracefulMods.ps1 -DryRun' {
        $before = Get-ShellState
        $r = Invoke-InstallScript -Name 'Install-WauGracefulMods.ps1' -Arguments @('-DryRun')
        $after = Get-ShellState

        It 'exits 0' { $r.ExitCode | Should Be 0 }
        It 'prints the WAU install command with the MSI properties' {
            $r.Output | Should Match 'winget install --id Romanitho\.Winget-AutoUpdate --exact --silent'
            $r.Output | Should Match '--override "/qn /norestart UPDATESATLOGON=1 UPDATESINTERVAL=Never USERCONTEXT=1 USEWHITELIST=1 NOTIFICATIONLEVEL=Full DISABLEWAUAUTOUPDATE=1"'
        }
        It 'plans the data folder lock-down before the WAU install' {
            $r.Output | Should Match 'state and \\backups, remove inheritance, allow only SYSTEM and Administrators'
            $r.Output.IndexOf('remove inheritance') | Should BeLessThan $r.Output.IndexOf('winget install')
        }
        It 'prints the whitelist, runtime, mods, tasks and permission steps' {
            $r.Output | Should Match 'included_apps\.txt'
            $r.Output | Should Match 'copy the runtime'
            $r.Output | Should Match 'thin per-app mods'
            $r.Output | Should Match "register tasks 'qbittorrent-close' and 'qbittorrent-open'"
            $r.Output | Should Match 'installed-files\.json'
            $r.Output | Should Match 'check that no non-admin principal can write'
        }
        It 'says nothing was changed and changes nothing' {
            $r.Output | Should Match 'Nothing was changed'
            $after | Should Be $before
        }
    }

    Context 'Uninstall-WauGracefulMods.ps1 -DryRun' {
        $before = Get-ShellState
        $r = Invoke-InstallScript -Name 'Uninstall-WauGracefulMods.ps1' -Arguments @('-DryRun', '-RemoveWau')
        $after = Get-ShellState

        It 'exits 0' { $r.ExitCode | Should Be 0 }
        It 'prints the plan' {
            $r.Output | Should Match "unregister tasks 'qbittorrent-close' and 'qbittorrent-open'"
            $r.Output | Should Match 'winget uninstall --id Romanitho\.Winget-AutoUpdate --exact --silent'
            $r.Output | Should Match 'remove the task folder \\wau-graceful-mods\\ if it is empty'
        }
        It 'says nothing was changed and changes nothing' {
            $r.Output | Should Match 'Nothing was changed'
            $after | Should Be $before
        }
    }

    Context 'without -DryRun while not elevated' {
        It 'the installer refuses before changing anything' {
            if (Test-GwmElevated) { Set-TestInconclusive 'elevated: a real run would not be refused, so it is not tried'; return }
            $before = Get-ShellState
            $r = Invoke-InstallScript -Name 'Install-WauGracefulMods.ps1' -Arguments @()
            $r.ExitCode | Should Be 1
            $r.Output | Should Match 'not elevated'
            (Get-ShellState) | Should Be $before
        }
        It 'the uninstaller refuses before changing anything' {
            if (Test-GwmElevated) { Set-TestInconclusive 'elevated: a real run would not be refused, so it is not tried'; return }
            $before = Get-ShellState
            $r = Invoke-InstallScript -Name 'Uninstall-WauGracefulMods.ps1' -Arguments @()
            $r.ExitCode | Should Be 1
            $r.Output | Should Match 'not elevated'
            (Get-ShellState) | Should Be $before
        }
    }
}
