Set-StrictMode -Version 2

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'src\lib\Log.ps1')
. (Join-Path $root 'src\lib\Manifest.ps1')
. (Join-Path $root 'src\lib\Process.ps1')
. (Join-Path $root 'src\lib\ReopenMarker.ps1')
. (Join-Path $root 'src\lib\ModLogic.ps1')

# Stubs with the signatures of the functions that live in other libraries. Everything
# below Mocks them, so no real window is closed and no real scheduled task is touched.
function Close-App {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName,
        [string[]]$HiddenWindowClass,
        [int]$TimeoutSec = 30,
        [int]$PollMs = 250
    )
}
function Invoke-GwmTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)][ValidateSet('close', 'open')][string]$Action,
        [string]$TaskFolder = '\wau-graceful-mods\',
        [int]$TimeoutSec = 30,
        [int]$PollMs = 500
    )
}
function Test-GwmInteractiveSession {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
}

$script:tmp = [System.IO.Path]::GetFullPath($env:TEMP)
$script:savedStateDir = $env:GWM_STATE_DIR
$script:work = $null
$script:manifestPath = $null

$script:manifestText = @'
@{
    SchemaVersion = 1
    TaskFolder    = '\gwm-test\'
    SelfId        = 'Fake.Self'
    Apps          = @(
        @{ Id = 'Fake.Machine';       Process = 'gwmfakem';  Scope = 'machine'; Policy = 'close-reopen'; Exe = @('C:\fake\gwmfakem.exe') }
        @{ Id = 'Fake.MachineBackup'; Process = 'gwmfakemb'; Scope = 'machine'; Policy = 'close-reopen'; Exe = @('C:\fake\gwmfakemb.exe'); BackupOnMajorUpgrade = '%APPDATA%\fake-mb' }
        @{ Id = 'Fake.User';          Process = 'gwmfakeu';  Scope = 'user';    Policy = 'close-reopen'; Exe = @('C:\fake\gwmfakeu.exe'); HiddenWindowClass = @('GwmFake*Class', 'GwmOther') }
        @{ Id = 'Fake.UserBackup';    Process = 'gwmfakeub'; Scope = 'user';    Policy = 'close-reopen'; Exe = @('C:\fake\gwmfakeub.exe'); BackupOnMajorUpgrade = '%APPDATA%\fake-ub' }
        @{ Id = 'Fake.Skip';          Process = 'gwmskip';   Scope = 'user';    Policy = 'skip-if-open' }
        @{ Id = 'Fake.Auto';          Process = 'gwmauto';   Scope = 'user';    Policy = 'skip-if-open'; Autostart = $true }
        @{ Id = 'Fake.Auto2';         Process = 'gwmauto2';  Scope = 'machine'; Policy = 'close-reopen'; Autostart = $true; Exe = @('C:\fake\gwmauto2.exe') }
    )
}
'@

function New-WorkDir {
    $script:work = Join-Path $script:tmp ('gwm-modlogic-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:work | Out-Null
    $env:GWM_STATE_DIR = Join-Path $script:work 'state'
    $script:manifestPath = Join-Path $script:work 'apps.psd1'
    Set-Content -LiteralPath $script:manifestPath -Value $script:manifestText -Encoding ASCII
}

function Remove-WorkDir {
    $env:GWM_STATE_DIR = $script:savedStateDir
    if ($script:work) {
        Remove-Item -LiteralPath $script:work -Recurse -Force -ErrorAction SilentlyContinue
        $script:work = $null
    }
}

# Runs a mod entry point and checks the pipeline carried exactly one value of the type.
function Get-OneValue {
    param([object[]]$Output, [type]$Type)
    # Pester 3.4 Should emits $true on success; keep it off this function's output.
    @($Output).Count | Should Be 1 | Out-Null
    ($Output[0] -is $Type) | Should Be $true | Out-Null
    $Output[0]
}

# Pester 3.4 keeps a mock's call history across tests when the Mock line is re-run in
# BeforeEach, so the flow tests count calls through their own log instead.
function Get-CallCount {
    param([string]$Fn, [scriptblock]$Where = { $true })
    @($script:calls | Where-Object { $_.Fn -eq $Fn } | Where-Object $Where).Count
}

Describe 'Test-GwmMajorUpgrade' {
    $app = @{ Id = 'Fake.Machine'; Process = 'gwmfakem'; Scope = 'machine'; Policy = 'close-reopen'; Exe = @('C:\fake\gwmfakem.exe') }

    BeforeEach {
        $script:exeMajor = $null
        $script:resolved = 'C:\fake\gwmfakem.exe'
        Mock Resolve-GwmExe { $script:resolved }
        Mock Get-GwmExeMajorVersion { $script:exeMajor }
    }

    It 'is true when the available major is greater' {
        Test-GwmMajorUpgrade -InstalledVersion '1.9.9' -AvailableVersion '2.0.0' | Should Be $true
    }
    It 'is false for the same major' {
        Test-GwmMajorUpgrade -InstalledVersion '2.1' -AvailableVersion '2.9' | Should Be $false
    }
    It 'is false for a lower available major' {
        Test-GwmMajorUpgrade -InstalledVersion '3.0' -AvailableVersion '2.0' | Should Be $false
    }
    It 'compares majors as numbers, not strings' {
        Test-GwmMajorUpgrade -InstalledVersion '9.0' -AvailableVersion '10.0' | Should Be $true
        Test-GwmMajorUpgrade -InstalledVersion '10.0' -AvailableVersion '9.0' | Should Be $false
    }
    It 'accepts a leading v' {
        Test-GwmMajorUpgrade -InstalledVersion 'v1.0' -AvailableVersion 'v2.0' | Should Be $true
    }
    It 'emits exactly one bool' {
        $out = @(Test-GwmMajorUpgrade -InstalledVersion '1.0' -AvailableVersion '2.0')
        Get-OneValue -Output $out -Type ([bool]) | Should Be $true
    }
    It 'does not look at the exe when the installed version is known' {
        Test-GwmMajorUpgrade -InstalledVersion '1.0' -AvailableVersion '1.5' -App $app | Should Be $false
        Assert-MockCalled Resolve-GwmExe -Exactly -Times 0
    }
    It 'falls back to the exe file version when the installed version is empty' {
        $script:exeMajor = 4
        Test-GwmMajorUpgrade -InstalledVersion '' -AvailableVersion '5.0' -App $app | Should Be $true
        $script:exeMajor = 5
        Test-GwmMajorUpgrade -InstalledVersion '' -AvailableVersion '5.1' -App $app | Should Be $false
    }
    It 'falls back to the exe file version when the installed version starts with <' {
        $script:exeMajor = 7
        Test-GwmMajorUpgrade -InstalledVersion '< 7.0' -AvailableVersion '7.2' -App $app | Should Be $false
        $script:exeMajor = 6
        Test-GwmMajorUpgrade -InstalledVersion '< 7.0' -AvailableVersion '7.2' -App $app | Should Be $true
    }
    It 'is true (conservative) when the exe cannot be resolved' {
        $script:resolved = $null
        Test-GwmMajorUpgrade -InstalledVersion '' -AvailableVersion '5.0' -App $app | Should Be $true
    }
    It 'is true (conservative) when the exe has no readable version' {
        $script:exeMajor = $null
        Test-GwmMajorUpgrade -InstalledVersion '<unknown>' -AvailableVersion '5.0' -App $app | Should Be $true
    }
    It 'is true (conservative) when no app is given and the installed version is unknown' {
        Test-GwmMajorUpgrade -InstalledVersion '' -AvailableVersion '5.0' | Should Be $true
    }
    It 'is true (conservative) when the available version has no major' {
        Test-GwmMajorUpgrade -InstalledVersion '1.0' -AvailableVersion '' | Should Be $true
        Test-GwmMajorUpgrade -InstalledVersion '1.0' -AvailableVersion 'latest' | Should Be $true
    }
    It 'passes the user context on to Resolve-GwmExe' {
        $ctx = [pscustomobject]@{ UserSid = 'S-fake'; ProfilePath = 'C:\Users\fake-user' }
        Test-GwmMajorUpgrade -InstalledVersion '' -AvailableVersion '5.0' -App $app -UserContext $ctx | Out-Null
        Assert-MockCalled Resolve-GwmExe -Exactly -Times 1 -ParameterFilter { $UserContext.UserSid -eq 'S-fake' }
    }
}

Describe 'Get-GwmExeMajorVersion' {
    It 'reads the major part of a real file version' {
        $exe = Join-Path $PSHOME 'powershell.exe'
        $expected = (Get-Item -LiteralPath $exe).VersionInfo.FileMajorPart
        Get-GwmExeMajorVersion -Path $exe | Should Be $expected
    }
    It 'returns null for a missing file' {
        $missing = Join-Path $script:tmp ('gwm-nope-{0}.exe' -f [guid]::NewGuid().ToString('N'))
        Get-GwmExeMajorVersion -Path $missing | Should BeNullOrEmpty
    }
}

Describe 'Backup-GwmAppData' {
    BeforeEach {
        New-WorkDir
        Mock Write-GwmLog { }
        $script:src = Join-Path $script:work 'src-data'
        $script:backups = Join-Path $script:work 'backups'
        New-Item -ItemType Directory -Path (Join-Path $script:src 'sub') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:src 'a.txt') -Value 'alpha' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $script:src 'sub\b.txt') -Value 'beta' -Encoding ASCII
        $script:bApp = @{ Id = 'Fake.B'; Process = 'gwmfakeb'; Scope = 'machine'; Policy = 'close-reopen'; Exe = @('C:\fake\b.exe'); BackupOnMajorUpgrade = $script:src }
    }
    AfterEach { Remove-WorkDir }

    It 'copies the tree to <BackupRoot>\<Process>-<timestamp> and returns that path' {
        $dest = @(Backup-GwmAppData -App $script:bApp -BackupRoot $script:backups)
        $dest.Count | Should Be 1
        $dest[0] | Should Match '\\gwmfakeb-\d{8}-\d{6}'
        (Split-Path -Parent $dest[0]) | Should Be $script:backups
        (Get-Content -LiteralPath (Join-Path $dest[0] 'a.txt') -Raw).Trim() | Should Be 'alpha'
        (Get-Content -LiteralPath (Join-Path $dest[0] 'sub\b.txt') -Raw).Trim() | Should Be 'beta'
    }
    It 'keeps both backups when two are taken within the same second' {
        $one = Backup-GwmAppData -App $script:bApp -BackupRoot $script:backups -Keep 5
        $two = Backup-GwmAppData -App $script:bApp -BackupRoot $script:backups -Keep 5
        $one | Should Not Be $two
        Test-Path -LiteralPath $one | Should Be $true
        Test-Path -LiteralPath $two | Should Be $true
    }
    It 'keeps only the newest -Keep backups of that process' {
        New-Item -ItemType Directory -Path $script:backups -Force | Out-Null
        foreach ($n in 'gwmfakeb-20200101-000000', 'gwmfakeb-20200102-000000', 'gwmfakeb-20200103-000000', 'gwmfakeb-helper-20200101-000000', 'other-20200101-000000') {
            New-Item -ItemType Directory -Path (Join-Path $script:backups $n) | Out-Null
        }
        $dest = Backup-GwmAppData -App $script:bApp -BackupRoot $script:backups -Keep 2
        $left = @(Get-ChildItem -LiteralPath $script:backups -Directory | ForEach-Object { $_.Name } | Sort-Object)
        ($left -contains (Split-Path -Leaf $dest)) | Should Be $true
        ($left -contains 'gwmfakeb-20200103-000000') | Should Be $true
        ($left -contains 'gwmfakeb-20200101-000000') | Should Be $false
        ($left -contains 'gwmfakeb-20200102-000000') | Should Be $false
        # Another process, and a process whose name only starts like ours, are never pruned.
        ($left -contains 'gwmfakeb-helper-20200101-000000') | Should Be $true
        ($left -contains 'other-20200101-000000') | Should Be $true
    }
    It 'expands per-user variables through the user context' {
        $profile = Join-Path $script:work 'fake-profile'
        New-Item -ItemType Directory -Path (Join-Path $profile 'AppData\Roaming\fake-mb') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $profile 'AppData\Roaming\fake-mb\x.txt') -Value 'x' -Encoding ASCII
        $app = @{ Id = 'Fake.MB'; Process = 'gwmfakemb'; Scope = 'machine'; Policy = 'close-reopen'; Exe = @('C:\fake\mb.exe'); BackupOnMajorUpgrade = '%APPDATA%\fake-mb' }
        $ctx = [pscustomobject]@{ UserSid = 'S-fake'; ProfilePath = $profile }
        $dest = Backup-GwmAppData -App $app -UserContext $ctx -BackupRoot $script:backups
        Test-Path -LiteralPath (Join-Path $dest 'x.txt') | Should Be $true
    }
    It 'throws when the source folder does not exist, and leaves no backup behind' {
        $app = $script:bApp.Clone()
        $app.BackupOnMajorUpgrade = Join-Path $script:work 'missing'
        { Backup-GwmAppData -App $app -BackupRoot $script:backups } | Should Throw
        @(Get-ChildItem -LiteralPath $script:backups -ErrorAction SilentlyContinue).Count | Should Be 0
    }
    It 'throws when the app has no BackupOnMajorUpgrade' {
        $app = @{ Id = 'Fake.N'; Process = 'gwmfaken'; Scope = 'machine'; Policy = 'close-reopen'; Exe = @('C:\fake\n.exe') }
        { Backup-GwmAppData -App $app -BackupRoot $script:backups } | Should Throw
    }
    It 'does not follow a junction inside the source' {
        $outside = Join-Path $script:work 'outside'
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'secret.txt') -Value 'secret' -Encoding ASCII
        $link = Join-Path $script:src 'link'
        & cmd.exe /c "mklink /J `"$link`" `"$outside`"" | Out-Null
        Test-Path -LiteralPath (Join-Path $link 'secret.txt') | Should Be $true
        $dest = Backup-GwmAppData -App $script:bApp -BackupRoot $script:backups
        Test-Path -LiteralPath (Join-Path $dest 'a.txt') | Should Be $true
        Test-Path -LiteralPath (Join-Path $dest 'link') | Should Be $false
        # Remove the junction itself first so cleanup cannot reach the target through it.
        & cmd.exe /c "rmdir `"$link`"" | Out-Null
    }
    It 'refuses a source folder that is itself a junction' {
        $outside = Join-Path $script:work 'outside2'
        New-Item -ItemType Directory -Path $outside | Out-Null
        Set-Content -LiteralPath (Join-Path $outside 'secret.txt') -Value 'secret' -Encoding ASCII
        $link = Join-Path $script:work 'rootlink'
        & cmd.exe /c "mklink /J `"$link`" `"$outside`"" | Out-Null
        $app = $script:bApp.Clone()
        $app.BackupOnMajorUpgrade = $link
        try {
            { Backup-GwmAppData -App $app -BackupRoot $script:backups } | Should Throw
        }
        finally {
            & cmd.exe /c "rmdir `"$link`"" | Out-Null
        }
    }
}

Describe 'Backup-GwmAppData when the copy fails' {
    BeforeEach {
        New-WorkDir
        Mock Write-GwmLog { }
        $script:src = Join-Path $script:work 'src-data'
        $script:backups = Join-Path $script:work 'backups'
        New-Item -ItemType Directory -Path $script:src -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $script:src 'a.txt') -Value 'alpha' -Encoding ASCII
        $script:bApp = @{ Id = 'Fake.B'; Process = 'gwmfakeb'; Scope = 'machine'; Policy = 'close-reopen'; Exe = @('C:\fake\b.exe'); BackupOnMajorUpgrade = $script:src }
    }
    AfterEach { Remove-WorkDir }

    It 'throws when the copy fails and removes the partial copy' {
        Mock Copy-Item { throw 'disk full' }
        { Backup-GwmAppData -App $script:bApp -BackupRoot $script:backups } | Should Throw
        @(Get-ChildItem -LiteralPath $script:backups -ErrorAction SilentlyContinue).Count | Should Be 0
    }
}

Describe 'mod flow' {
    BeforeEach {
        New-WorkDir
        $script:running = @{}
        $script:closeCompleted = $true
        $script:closeResult = 0
        $script:closeReason = 'done'
        $script:closeExits = $true
        $script:closeAppExited = $true
        $script:closeAppKills = $true
        $script:openCompleted = $true
        $script:openResult = 0
        $script:majorUpgrade = $false
        $script:backupThrows = $false
        $script:backupCalls = 0
        $script:resolved = 'C:\fake\app.exe'
        $script:startThrows = $false
        $script:started = @()
        $script:shellUp = $true
        $script:settleCalls = 0
        $script:isSystem = $false

        $script:calls = @()
        Mock Write-GwmLog { $script:calls += [pscustomobject]@{ Fn = 'Write-GwmLog'; Message = $Message } }
        Mock Test-GwmProcessRunning { $script:calls += [pscustomobject]@{ Fn = 'Test-GwmProcessRunning' }; [bool]$script:running[$ProcessName] }
        Mock Resolve-GwmExe { $script:resolved }
        Mock Stop-Process { $script:calls += [pscustomobject]@{ Fn = 'Stop-Process' } }
        Mock Test-GwmInteractiveSession { $script:settleCalls++; $script:shellUp }
        Mock Test-GwmMajorUpgrade { $script:calls += [pscustomobject]@{ Fn = 'Test-GwmMajorUpgrade'; InstalledVersion = $InstalledVersion; AvailableVersion = $AvailableVersion }; $script:majorUpgrade }
        Mock Backup-GwmAppData {
            $script:calls += [pscustomobject]@{ Fn = 'Backup-GwmAppData' }
            if ($script:backupThrows) { throw 'disk full' }
            $script:backupCalls++
            'C:\fake\backup'
        }
        Mock Close-App {
            $script:calls += [pscustomobject]@{ Fn = 'Close-App'; ProcessName = $ProcessName; TimeoutSec = $TimeoutSec; HasHidden = ($null -ne $HiddenWindowClass); Hidden = $HiddenWindowClass }
            if ($script:closeAppKills) { $script:running[$ProcessName] = $false }
            [pscustomobject]@{ ProcessName = $ProcessName; Found = $true; Exited = $script:closeAppExited; Reason = 'exited' }
        }
        Mock Invoke-GwmTask {
            $script:calls += [pscustomobject]@{ Fn = 'Invoke-GwmTask'; Action = $Action; Process = $App.Process; TaskFolder = $TaskFolder; TimeoutSec = $TimeoutSec }
            if ($Action -eq 'close') {
                if ($script:closeExits) { $script:running[$App.Process] = $false }
                [pscustomobject]@{ Started = $true; Completed = $script:closeCompleted; Result = $script:closeResult; Reason = $script:closeReason }
            }
            else {
                if ($script:openCompleted -and $script:openResult -eq 0) { $script:running[$App.Process] = $true }
                [pscustomobject]@{ Started = $true; Completed = $script:openCompleted; Result = $script:openResult; Reason = 'done' }
            }
        }
        Mock Test-GwmRunningAsSystem { $script:isSystem }
        Mock Start-Process {
            $script:calls += [pscustomobject]@{ Fn = 'Start-Process'; FilePath = $FilePath }
            if ($script:startThrows) { throw 'cannot start' }
            $script:started += $FilePath
        }
    }
    AfterEach { Remove-WorkDir }

    Context 'Invoke-GwmReopen' {
        $machine = @{ Id = 'Fake.Machine'; Process = 'gwmfakem'; Scope = 'machine'; Policy = 'close-reopen'; Exe = @('C:\fake\gwmfakem.exe') }
        $user = @{ Id = 'Fake.User'; Process = 'gwmfakeu'; Scope = 'user'; Policy = 'close-reopen'; Exe = @('C:\fake\gwmfakeu.exe'); HiddenWindowClass = @('GwmFake*Class', 'GwmOther') }

        It 'machine scope: opens through the task and reports success' {
            $out = @(Invoke-GwmReopen -App $machine -TaskFolder '\gwm-test\')
            Get-OneValue -Output $out -Type ([bool]) | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'open' -and $_.Process -eq 'gwmfakem' -and $_.TaskFolder -eq '\gwm-test\' }) | Should Be 1
        }
        It 'machine scope: uses the production task folder when none is given' {
            Invoke-GwmReopen -App $machine | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'open' -and $_.TaskFolder -eq '\wau-graceful-mods\' }) | Should Be 1
        }
        It 'machine scope: a task that did not complete is a failure' {
            $script:openCompleted = $false
            Invoke-GwmReopen -App $machine -TaskFolder '\gwm-test\' | Should Be $false
        }
        It 'machine scope: a non-zero task result is a failure' {
            $script:openResult = 2
            Invoke-GwmReopen -App $machine -TaskFolder '\gwm-test\' | Should Be $false
        }
        It 'user scope: starts the resolved exe as the current user' {
            $out = @(Invoke-GwmReopen -App $user)
            Get-OneValue -Output $out -Type ([bool]) | Should Be $true
            $script:started.Count | Should Be 1
            $script:started[0] | Should Be 'C:\fake\app.exe'
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
        }
        It 'user scope: an already running app is a success and is not started again' {
            $script:running['gwmfakeu'] = $true
            Invoke-GwmReopen -App $user | Should Be $true
            (Get-CallCount 'Start-Process' {}) | Should Be 0
        }
        It 'user scope: never starts the exe as SYSTEM' {
            $script:isSystem = $true
            $out = @(Invoke-GwmReopen -App $user)
            Get-OneValue -Output $out -Type ([bool]) | Should Be $false
            (Get-CallCount 'Start-Process' {}) | Should Be 0
        }
        It 'machine scope: is not affected by running as SYSTEM' {
            $script:isSystem = $true
            Invoke-GwmReopen -App $machine -TaskFolder '\gwm-test\' | Should Be $true
        }
        It 'user scope: fails when the exe cannot be resolved' {
            $script:resolved = $null
            Invoke-GwmReopen -App $user | Should Be $false
            (Get-CallCount 'Start-Process' {}) | Should Be 0
        }
        It 'user scope: fails when starting throws' {
            $script:startThrows = $true
            $out = @(Invoke-GwmReopen -App $user)
            Get-OneValue -Output $out -Type ([bool]) | Should Be $false
        }
    }

    Context 'Invoke-GwmPreInstall' {
        function Invoke-Pre {
            param([string]$AppId, [string]$Installed = '1.0', [string]$Available = '2.0', [switch]$DefaultTimeout)
            if ($DefaultTimeout) {
                $out = @(Invoke-GwmPreInstall -AppId $AppId -InstalledVersion $Installed -AvailableVersion $Available -ManifestPath $script:manifestPath)
            }
            else {
                $out = @(Invoke-GwmPreInstall -AppId $AppId -InstalledVersion $Installed -AvailableVersion $Available -ManifestPath $script:manifestPath -TimeoutSec 7)
            }
            Get-OneValue -Output $out -Type ([bool])
        }

        It 'lets an app that is not in the manifest proceed' {
            Invoke-Pre -AppId 'Unknown.App' | Should Be $true
            (Get-CallCount 'Test-GwmProcessRunning' {}) | Should Be 0
        }
        It 'skip-if-open: skips while the process runs' {
            $script:running['gwmskip'] = $true
            Invoke-Pre -AppId 'Fake.Skip' | Should Be $false
        }
        It 'skip-if-open: proceeds when the process is not running' {
            Invoke-Pre -AppId 'Fake.Skip' | Should Be $true
        }
        It 'skip-if-open: never closes anything' {
            $script:running['gwmskip'] = $true
            Invoke-Pre -AppId 'Fake.Skip' | Out-Null
            (Get-CallCount 'Close-App' {}) | Should Be 0
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
        }
        It 'close-reopen: proceeds without a marker when the app is not running' {
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $true
            @(Get-GwmReopenOwed).Count | Should Be 0
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
            (Get-CallCount 'Close-App' {}) | Should Be 0
        }
        It 'machine scope: closes through the task, sets the marker, proceeds' {
            $script:running['gwmfakem'] = $true
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'close' -and $_.Process -eq 'gwmfakem' -and $_.TaskFolder -eq '\gwm-test\' -and $_.TimeoutSec -eq 27 }) | Should Be 1
            (Get-CallCount 'Close-App' {}) | Should Be 0
            (@(Get-GwmReopenOwed) -contains 'gwmfakem') | Should Be $true
        }
        It 'user scope: closes through Close-App, sets the marker, proceeds' {
            $script:running['gwmfakeu'] = $true
            Invoke-Pre -AppId 'Fake.User' | Should Be $true
            (Get-CallCount 'Close-App' { $_.ProcessName -eq 'gwmfakeu' -and $_.TimeoutSec -eq 7 }) | Should Be 1
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
            (@(Get-GwmReopenOwed) -contains 'gwmfakeu') | Should Be $true
        }
        It 'machine scope: gives the close task 20 seconds more than the wrapper waits for the app' {
            $script:running['gwmfakem'] = $true
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'close' -and $_.TimeoutSec -eq 27 }) | Should Be 1
        }
        It 'defaults the close timeout to 60 seconds for user scope' {
            $script:running['gwmfakeu'] = $true
            Invoke-Pre -AppId 'Fake.User' -DefaultTimeout | Should Be $true
            (Get-CallCount 'Close-App' { $_.ProcessName -eq 'gwmfakeu' -and $_.TimeoutSec -eq 60 }) | Should Be 1
        }
        It 'defaults the close task timeout to 80 seconds for machine scope' {
            $script:running['gwmfakem'] = $true
            Invoke-Pre -AppId 'Fake.Machine' -DefaultTimeout | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'close' -and $_.TimeoutSec -eq 80 }) | Should Be 1
        }
        It 'machine scope: a task that reports timeout still counts as exited when the process is gone by decision time' {
            $script:running['gwmfakem'] = $true
            $script:closeCompleted = $false
            $script:closeResult = 0
            $script:closeReason = 'timeout'
            $script:closeExits = $true
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $true
            (@(Get-GwmReopenOwed) -contains 'gwmfakem') | Should Be $true
        }
        It 'machine scope: a task that reports timeout with the process still running clears the marker and skips' {
            $script:running['gwmfakem'] = $true
            $script:closeCompleted = $false
            $script:closeReason = 'timeout'
            $script:closeExits = $false
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $false
            @(Get-GwmReopenOwed).Count | Should Be 0
        }
        It 'user scope: passes the app HiddenWindowClass patterns to Close-App' {
            $script:running['gwmfakeu'] = $true
            Invoke-Pre -AppId 'Fake.User' | Should Be $true
            (Get-CallCount 'Close-App' { $_.HasHidden -and $_.Hidden.Count -eq 2 -and ($_.Hidden -contains 'GwmFake*Class') -and ($_.Hidden -contains 'GwmOther') }) | Should Be 1
        }
        It 'user scope: leaves HiddenWindowClass out when the app does not set it' {
            $script:running['gwmfakeub'] = $true
            Invoke-Pre -AppId 'Fake.UserBackup' | Should Be $true
            (Get-CallCount 'Close-App' { $_.ProcessName -eq 'gwmfakeub' -and -not $_.HasHidden }) | Should Be 1
        }
        It 'sets the marker before it closes' {
            $script:running['gwmfakem'] = $true
            $script:markerSeenAtClose = $null
            Mock Invoke-GwmTask {
                $script:markerSeenAtClose = (@(Get-GwmReopenOwed) -contains 'gwmfakem')
                $script:running[$App.Process] = $false
                [pscustomobject]@{ Started = $true; Completed = $true; Result = 0; Reason = 'done' }
            }
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $true
            $script:markerSeenAtClose | Should Be $true
        }
        It 'machine scope: a completed task with result 0 counts as exited' {
            $script:running['gwmfakem'] = $true
            $script:closeExits = $false
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $true
        }
        It 'machine scope: the process being gone counts as exited even if the task reports failure' {
            $script:running['gwmfakem'] = $true
            $script:closeCompleted = $false
            $script:closeResult = 1
            $script:closeExits = $true
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $true
        }
        It 'machine scope: close that does not exit the app clears the marker, skips, and kills nothing' {
            $script:running['gwmfakem'] = $true
            $script:closeCompleted = $true
            $script:closeResult = 1
            $script:closeExits = $false
            Invoke-Pre -AppId 'Fake.Machine' | Should Be $false
            @(Get-GwmReopenOwed).Count | Should Be 0
            (Get-CallCount 'Stop-Process' {}) | Should Be 0
            (Get-CallCount 'Backup-GwmAppData' {}) | Should Be 0
        }
        It 'user scope: close that does not exit the app clears the marker, skips, and kills nothing' {
            $script:running['gwmfakeu'] = $true
            $script:closeAppExited = $false
            $script:closeAppKills = $false
            Invoke-Pre -AppId 'Fake.User' | Should Be $false
            @(Get-GwmReopenOwed).Count | Should Be 0
            (Get-CallCount 'Stop-Process' {}) | Should Be 0
        }
        It 'user scope: the process being gone counts as exited even if Close-App reports otherwise' {
            $script:running['gwmfakeu'] = $true
            $script:closeAppExited = $false
            $script:closeAppKills = $true
            Invoke-Pre -AppId 'Fake.User' | Should Be $true
        }
        It 'does not look at versions for an app without BackupOnMajorUpgrade' {
            $script:running['gwmfakem'] = $true
            Invoke-Pre -AppId 'Fake.Machine' | Out-Null
            (Get-CallCount 'Test-GwmMajorUpgrade' {}) | Should Be 0
            (Get-CallCount 'Backup-GwmAppData' {}) | Should Be 0
        }
        It 'backs up after the close on a major upgrade and keeps the marker' {
            $script:running['gwmfakemb'] = $true
            $script:majorUpgrade = $true
            Invoke-Pre -AppId 'Fake.MachineBackup' -Installed '1.5' -Available '2.0' | Should Be $true
            $script:backupCalls | Should Be 1
            (Get-CallCount 'Test-GwmMajorUpgrade' { $_.InstalledVersion -eq '1.5' -and $_.AvailableVersion -eq '2.0' }) | Should Be 1
            (@(Get-GwmReopenOwed) -contains 'gwmfakemb') | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'open' }) | Should Be 0
        }
        It 'does not back up when the upgrade is not a major one' {
            $script:running['gwmfakemb'] = $true
            $script:majorUpgrade = $false
            Invoke-Pre -AppId 'Fake.MachineBackup' | Should Be $true
            (Get-CallCount 'Backup-GwmAppData' {}) | Should Be 0
        }
        It 'does not back up when the close failed' {
            $script:running['gwmfakemb'] = $true
            $script:majorUpgrade = $true
            $script:closeCompleted = $false
            $script:closeResult = 1
            $script:closeExits = $false
            Invoke-Pre -AppId 'Fake.MachineBackup' | Should Be $false
            (Get-CallCount 'Backup-GwmAppData' {}) | Should Be 0
        }
        It 'machine scope: a failing backup reopens the app, clears the marker and skips the update' {
            $script:running['gwmfakemb'] = $true
            $script:majorUpgrade = $true
            $script:backupThrows = $true
            Invoke-Pre -AppId 'Fake.MachineBackup' | Should Be $false
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'open' -and $_.Process -eq 'gwmfakemb' }) | Should Be 1
            @(Get-GwmReopenOwed).Count | Should Be 0
        }
        It 'user scope: a failing backup reopens the app, clears the marker and skips the update' {
            $script:running['gwmfakeub'] = $true
            $script:majorUpgrade = $true
            $script:backupThrows = $true
            Invoke-Pre -AppId 'Fake.UserBackup' | Should Be $false
            $script:started.Count | Should Be 1
            @(Get-GwmReopenOwed).Count | Should Be 0
        }
        It 'keeps the marker when the backup failed and the reopen failed too' {
            $script:running['gwmfakemb'] = $true
            $script:majorUpgrade = $true
            $script:backupThrows = $true
            $script:openCompleted = $false
            Invoke-Pre -AppId 'Fake.MachineBackup' | Should Be $false
            (@(Get-GwmReopenOwed) -contains 'gwmfakemb') | Should Be $true
        }
        It 'skips the app (fails closed) when the manifest cannot be read' {
            $out = @(Invoke-GwmPreInstall -AppId 'Fake.Machine' -ManifestPath (Join-Path $script:work 'missing.psd1'))
            Get-OneValue -Output $out -Type ([bool]) | Should Be $false
        }
        It 'emits exactly one bool on every path' {
            $script:majorUpgrade = $true
            $cases = @(
                @{ Id = 'Unknown.App'; Run = $false },
                @{ Id = 'Fake.Skip'; Run = $true },
                @{ Id = 'Fake.Machine'; Run = $false },
                @{ Id = 'Fake.Machine'; Run = $true },
                @{ Id = 'Fake.User'; Run = $true },
                @{ Id = 'Fake.MachineBackup'; Run = $true },
                @{ Id = 'Fake.UserBackup'; Run = $true }
            )
            foreach ($case in $cases) {
                $script:running = @{}
                if ($case.Run) {
                    foreach ($p in 'gwmskip', 'gwmfakem', 'gwmfakeu', 'gwmfakemb', 'gwmfakeub') { $script:running[$p] = $true }
                }
                foreach ($mode in 0, 1, 2) {
                    $script:backupThrows = ($mode -eq 1)
                    $script:closeExits = ($mode -ne 2)
                    $script:closeAppKills = ($mode -ne 2)
                    $script:closeAppExited = ($mode -ne 2)
                    $script:closeCompleted = ($mode -ne 2)
                    $script:closeResult = [int]($mode -eq 2)
                    $out = @(Invoke-GwmPreInstall -AppId $case.Id -InstalledVersion '1.0' -AvailableVersion '2.0' -ManifestPath $script:manifestPath)
                    Get-OneValue -Output $out -Type ([bool]) | Out-Null
                    foreach ($p in 'gwmfakem', 'gwmfakeu', 'gwmfakemb', 'gwmfakeub') { Clear-GwmReopenOwed -ProcessName $p }
                    $script:running = @{}
                    if ($case.Run) {
                        foreach ($p in 'gwmskip', 'gwmfakem', 'gwmfakeu', 'gwmfakemb', 'gwmfakeub') { $script:running[$p] = $true }
                    }
                }
            }
        }
    }

    Context 'Invoke-GwmPostInstall' {
        function Invoke-Post {
            param([string]$AppId, [bool]$Succeeded = $true)
            $out = @(Invoke-GwmPostInstall -AppId $AppId -Succeeded $Succeeded -ManifestPath $script:manifestPath)
            Get-OneValue -Output $out -Type ([bool])
        }

        It 'reopens a close-reopen app that has a marker and clears it' {
            Set-GwmReopenOwed -ProcessName 'gwmfakem'
            Invoke-Post -AppId 'Fake.Machine' | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'open' -and $_.TaskFolder -eq '\gwm-test\' }) | Should Be 1
            @(Get-GwmReopenOwed).Count | Should Be 0
        }
        It 'reopens a user-scope app through Start-Process' {
            Set-GwmReopenOwed -ProcessName 'gwmfakeu'
            Invoke-Post -AppId 'Fake.User' | Should Be $true
            $script:started.Count | Should Be 1
            @(Get-GwmReopenOwed).Count | Should Be 0
        }
        It 'keeps the marker and still returns true when the reopen fails' {
            Set-GwmReopenOwed -ProcessName 'gwmfakem'
            $script:openCompleted = $false
            Invoke-Post -AppId 'Fake.Machine' | Should Be $true
            (@(Get-GwmReopenOwed) -contains 'gwmfakem') | Should Be $true
        }
        It 'reopens even when the update failed (Succeeded is only logged)' {
            Set-GwmReopenOwed -ProcessName 'gwmfakem'
            Invoke-Post -AppId 'Fake.Machine' -Succeeded $false | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'open' }) | Should Be 1
            @(Get-GwmReopenOwed).Count | Should Be 0
        }
        It 'does nothing for a close-reopen app without a marker' {
            Invoke-Post -AppId 'Fake.Machine' | Should Be $true
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
            (Get-CallCount 'Start-Process' {}) | Should Be 0
        }
        It 'leaves another app marker alone' {
            Set-GwmReopenOwed -ProcessName 'gwmfakeu'
            Invoke-Post -AppId 'Fake.Machine' | Should Be $true
            (@(Get-GwmReopenOwed) -contains 'gwmfakeu') | Should Be $true
        }
        It 'does nothing for a skip-if-open app' {
            Invoke-Post -AppId 'Fake.Skip' | Should Be $true
            (Get-CallCount 'Start-Process' {}) | Should Be 0
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
        }
        It 'returns true for an unknown app' {
            Invoke-Post -AppId 'Unknown.App' | Should Be $true
        }
        It 'returns true even when the manifest cannot be read' {
            $out = @(Invoke-GwmPostInstall -AppId 'Fake.Machine' -Succeeded $true -ManifestPath (Join-Path $script:work 'missing.psd1'))
            Get-OneValue -Output $out -Type ([bool]) | Should Be $true
        }
    }

    Context 'Invoke-GwmReconcile' {
        function Invoke-Reconcile {
            $out = @(Invoke-GwmReconcile -ManifestPath $script:manifestPath)
            Get-OneValue -Output $out -Type ([int])
        }

        It 'returns 0 when nothing is owed' {
            Invoke-Reconcile | Should Be 0
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
        }
        It 'clears the marker of a process that is running again, without reopening' {
            Set-GwmReopenOwed -ProcessName 'gwmfakem'
            $script:running['gwmfakem'] = $true
            Invoke-Reconcile | Should Be 0
            @(Get-GwmReopenOwed).Count | Should Be 0
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
        }
        It 'reopens a process that is not running and clears its marker' {
            Set-GwmReopenOwed -ProcessName 'gwmfakem'
            Invoke-Reconcile | Should Be 1
            (Get-CallCount 'Invoke-GwmTask' { $_.Action -eq 'open' -and $_.Process -eq 'gwmfakem' }) | Should Be 1
            @(Get-GwmReopenOwed).Count | Should Be 0
        }
        It 'keeps the marker when the reopen fails and does not count it' {
            Set-GwmReopenOwed -ProcessName 'gwmfakem'
            $script:openCompleted = $false
            Invoke-Reconcile | Should Be 0
            (@(Get-GwmReopenOwed) -contains 'gwmfakem') | Should Be $true
        }
        It 'clears and logs a marker for a process the manifest does not know' {
            Set-GwmReopenOwed -ProcessName 'gwmstranger'
            Invoke-Reconcile | Should Be 0
            @(Get-GwmReopenOwed).Count | Should Be 0
            (Get-CallCount 'Invoke-GwmTask' {}) | Should Be 0
            (Get-CallCount 'Start-Process' {}) | Should Be 0
            ((Get-CallCount 'Write-GwmLog' { $_.Message -like '*gwmstranger*' }) -ge 1) | Should Be $true
        }
        It 'clears a marker that belongs to a skip-if-open app instead of launching it' {
            Set-GwmReopenOwed -ProcessName 'gwmskip'
            Invoke-Reconcile | Should Be 0
            @(Get-GwmReopenOwed).Count | Should Be 0
            (Get-CallCount 'Start-Process' {}) | Should Be 0
        }
        It 'handles several markers in one pass' {
            Set-GwmReopenOwed -ProcessName 'gwmfakem'
            Set-GwmReopenOwed -ProcessName 'gwmfakeu'
            Set-GwmReopenOwed -ProcessName 'gwmstranger'
            $script:running['gwmfakeu'] = $true
            Invoke-Reconcile | Should Be 1
            @(Get-GwmReopenOwed).Count | Should Be 0
        }
        It 'matches the process name ignoring case' {
            Set-GwmReopenOwed -ProcessName 'GwmFakeM'
            Invoke-Reconcile | Should Be 1
        }
        It 'returns 0 and keeps the markers when the manifest cannot be read' {
            Set-GwmReopenOwed -ProcessName 'gwmfakem'
            $out = @(Invoke-GwmReconcile -ManifestPath (Join-Path $script:work 'missing.psd1'))
            Get-OneValue -Output $out -Type ([int]) | Should Be 0
            (@(Get-GwmReopenOwed) -contains 'gwmfakem') | Should Be $true
        }
    }

    Context 'Wait-GwmSettle' {
        function Invoke-Settle {
            param([int]$MaxWaitSec = 1, [int]$PollSec = 1)
            $out = @(Wait-GwmSettle -ManifestPath $script:manifestPath -MaxWaitSec $MaxWaitSec -PollSec $PollSec)
            Get-OneValue -Output $out -Type ([pscustomobject])
        }

        It 'is settled at once when the shell and every autostart app are up' {
            $script:running['gwmauto'] = $true
            $script:running['gwmauto2'] = $true
            $r = Invoke-Settle -MaxWaitSec 30 -PollSec 5
            $r.Settled | Should Be $true
            $r.WaitedSec | Should Be 0
            @($r.Missing).Count | Should Be 0
        }
        It 'ignores apps that are not marked Autostart' {
            $script:running['gwmauto'] = $true
            $script:running['gwmauto2'] = $true
            $script:running['gwmfakem'] = $false
            (Invoke-Settle).Settled | Should Be $true
        }
        It 'returns Settled false with the missing processes at MaxWaitSec, without throwing' {
            $script:running['gwmauto'] = $true
            $r = Invoke-Settle -MaxWaitSec 1 -PollSec 1
            $r.Settled | Should Be $false
            (@($r.Missing) -contains 'gwmauto2') | Should Be $true
            (@($r.Missing) -contains 'gwmauto') | Should Be $false
            ($r.WaitedSec -ge 1) | Should Be $true
            ((Get-CallCount 'Write-GwmLog' { $_.Message -like '*gwmauto2*' }) -ge 1) | Should Be $true
        }
        It 'does not settle while no interactive shell exists' {
            $script:running['gwmauto'] = $true
            $script:running['gwmauto2'] = $true
            $script:shellUp = $false
            $r = Invoke-Settle -MaxWaitSec 1 -PollSec 1
            $r.Settled | Should Be $false
            @($r.Missing).Count | Should Be 0
        }
        It 'settles once the missing app shows up during the wait' {
            $script:running['gwmauto'] = $true
            $script:polls = 0
            Mock Test-GwmProcessRunning {
                if ($ProcessName -eq 'gwmauto2') { $script:polls++; return ($script:polls -gt 2) }
                return $true
            }
            $r = Invoke-Settle -MaxWaitSec 10 -PollSec 1
            $r.Settled | Should Be $true
            ($r.WaitedSec -ge 1) | Should Be $true
            @($r.Missing).Count | Should Be 0
        }
        It 'does not wait at all for a manifest without Autostart apps once the shell is up' {
            Set-Content -LiteralPath $script:manifestPath -Value "@{ Apps = @( @{ Id='A.B'; Process='gwmab'; Scope='user'; Policy='skip-if-open' } ) }" -Encoding ASCII
            $r = Invoke-Settle -MaxWaitSec 30 -PollSec 5
            $r.Settled | Should Be $true
            $r.WaitedSec | Should Be 0
        }
    }
}

Describe '_WAU-mods.ps1' {
    BeforeEach {
        New-WorkDir
        $script:modsDir = Join-Path $script:work 'mods'
        $libDir = Join-Path $script:modsDir 'gwm\lib'
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'src\mods\_WAU-mods.ps1') -Destination $script:modsDir
        $script:orderFile = Join-Path $script:work 'order.txt'
        $env:GWM_TEST_ORDER_FILE = $script:orderFile
        $fakeLoad = @'
function Write-GwmLog { param($Message) }
function Wait-GwmSettle {
    Add-Content -LiteralPath $env:GWM_TEST_ORDER_FILE -Value 'settle'
    if ($env:GWM_TEST_SETTLE_THROWS) { throw 'settle exploded' }
    if ($env:GWM_TEST_NOISY) {
        Write-Output '{"action":"run"}'
        Write-Warning 'noisy warning'
        Write-Error 'noisy non-terminating error' -ErrorAction Continue
        Write-Host 'noisy host text'
        & cmd.exe /c exit 3
    }
    [pscustomobject]@{ Settled = $true; WaitedSec = 0; Missing = @() }
}
function Invoke-GwmReconcile {
    Add-Content -LiteralPath $env:GWM_TEST_ORDER_FILE -Value 'reconcile'
    if ($env:GWM_TEST_NOISY) {
        Write-Output $env:GWM_TEST_NOISY_VALUE
        & cmd.exe /c exit 1
        return $false
    }
    3
}
'@
        Set-Content -LiteralPath (Join-Path $libDir 'Load.ps1') -Value $fakeLoad -Encoding ASCII
    }
    AfterEach {
        $env:GWM_TEST_ORDER_FILE = $null
        $env:GWM_TEST_SETTLE_THROWS = $null
        $env:GWM_TEST_NOISY = $null
        $env:GWM_TEST_NOISY_VALUE = $null
        Remove-WorkDir
    }

    It 'runs Wait-GwmSettle then Invoke-GwmReconcile and emits nothing' {
        $out = @(& (Join-Path $script:modsDir '_WAU-mods.ps1'))
        $out.Count | Should Be 0
        @(Get-Content -LiteralPath $script:orderFile) -join ',' | Should Be 'settle,reconcile'
    }
    It 'still reconciles, and does not throw, when the settle step fails' {
        $env:GWM_TEST_SETTLE_THROWS = '1'
        $out = @(& (Join-Path $script:modsDir '_WAU-mods.ps1'))
        $out.Count | Should Be 0
        @(Get-Content -LiteralPath $script:orderFile) -join ',' | Should Be 'settle,reconcile'
    }
    It 'emits nothing on any stream and ends with exit code 0 when helpers write output and leave a native exit code' {
        foreach ($value in '$true', '$false', '{"a":1}') {
            $env:GWM_TEST_NOISY = '1'
            $env:GWM_TEST_NOISY_VALUE = $value
            Remove-Item -LiteralPath $script:orderFile -ErrorAction SilentlyContinue
            $global:LASTEXITCODE = 7
            $out = @(& (Join-Path $script:modsDir '_WAU-mods.ps1') *>&1)
            $out.Count | Should Be 0
            $global:LASTEXITCODE | Should Be 0
            @(Get-Content -LiteralPath $script:orderFile) -join ',' | Should Be 'settle,reconcile'
        }
    }
    It 'ends with exit code 0 and no output when the settle step throws after a native failure' {
        $env:GWM_TEST_SETTLE_THROWS = '1'
        $global:LASTEXITCODE = 5
        $out = @(& (Join-Path $script:modsDir '_WAU-mods.ps1') *>&1)
        $out.Count | Should Be 0
        $global:LASTEXITCODE | Should Be 0
    }
}

Describe 'default paths when the caller is another script file' {
    $caller = Join-Path ([System.IO.Path]::GetFullPath($env:TEMP)) ('gwm-test-{0}.ps1' -f [guid]::NewGuid().ToString('N'))

    AfterEach { Remove-Item -LiteralPath $caller -Force -ErrorAction SilentlyContinue }

    It 'resolves the manifest and the user context next to the lib folder' {
        Set-Content -LiteralPath $caller -Value 'Get-GwmDefaultManifestPath; (Get-GwmModUserContext) | Out-Null' -Encoding ASCII
        $paths = @(& $caller)
        $paths[0] | Should Be (Join-Path (Join-Path $root 'src') 'apps.psd1')
    }
}
