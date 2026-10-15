$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'src\lib\Log.ps1')
. (Join-Path $root 'src\lib\Process.ps1')
. (Join-Path $root 'src\lib\ReopenMarker.ps1')

$script:tmp = [System.IO.Path]::GetFullPath($env:TEMP)
$script:savedStateDir = $env:GWM_STATE_DIR
$script:stateDir = $null

function Use-TempStateDir {
    $script:stateDir = Join-Path $script:tmp ('gwm-state-{0}' -f [guid]::NewGuid().ToString('N'))
    $env:GWM_STATE_DIR = $script:stateDir
}

function Remove-TempStateDir {
    $env:GWM_STATE_DIR = $script:savedStateDir
    if ($script:stateDir) {
        Remove-Item -LiteralPath $script:stateDir -Recurse -Force -ErrorAction SilentlyContinue
        $script:stateDir = $null
    }
}

Describe 'Get-GwmStateDir' {
    AfterEach { Remove-TempStateDir }

    It 'creates the folder named by GWM_STATE_DIR when it is missing' {
        Use-TempStateDir
        Test-Path -LiteralPath $script:stateDir | Should Be $false
        $dir = Get-GwmStateDir
        $dir | Should Be $script:stateDir
        Test-Path -LiteralPath $dir -PathType Container | Should Be $true
    }
    It 'emits exactly one string' {
        Use-TempStateDir
        @(Get-GwmStateDir).Count | Should Be 1
    }
    It 'uses the default location when GWM_STATE_DIR is unset' {
        $env:GWM_STATE_DIR = $null
        $script:defaultDir = Join-Path $script:tmp ('gwm-default-{0}' -f [guid]::NewGuid().ToString('N'))
        Mock Get-GwmDefaultStateDir { $script:defaultDir }
        try {
            Get-GwmStateDir | Should Be $script:defaultDir
            Test-Path -LiteralPath $script:defaultDir -PathType Container | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $script:defaultDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'lets GWM_STATE_DIR win over the default location' {
        Use-TempStateDir
        Mock Get-GwmDefaultStateDir { throw 'must not be asked' }
        Get-GwmStateDir | Should Be $script:stateDir
    }
}

Describe 'Get-GwmDefaultStateDir' {
    BeforeEach {
        $script:savedProgramData = $env:ProgramData
        $script:savedLocalAppData = $env:LOCALAPPDATA
        $env:ProgramData = 'C:\fake-programdata'
        $env:LOCALAPPDATA = 'C:\fake-user\AppData\Local'
    }
    AfterEach {
        $env:ProgramData = $script:savedProgramData
        $env:LOCALAPPDATA = $script:savedLocalAppData
    }

    It 'is under ProgramData for SYSTEM' {
        Mock Test-GwmRunningAsSystem { $true }
        Get-GwmDefaultStateDir | Should Be 'C:\fake-programdata\wau-graceful-mods\state'
    }
    It 'is under the per-user LOCALAPPDATA for anyone else' {
        Mock Test-GwmRunningAsSystem { $false }
        Get-GwmDefaultStateDir | Should Be 'C:\fake-user\AppData\Local\wau-graceful-mods\state'
    }
    It 'creates nothing' {
        Mock Test-GwmRunningAsSystem { $false }
        Mock New-Item { }
        Get-GwmDefaultStateDir | Out-Null
        Assert-MockCalled New-Item -Exactly -Times 0
        Test-Path -LiteralPath 'C:\fake-user\AppData\Local\wau-graceful-mods' | Should Be $false
    }
    It 'throws when the per-user location cannot be determined' {
        Mock Test-GwmRunningAsSystem { $false }
        $env:LOCALAPPDATA = $null
        { Get-GwmDefaultStateDir } | Should Throw
    }
}

Describe 'markers are per identity' {
    BeforeEach {
        $script:savedStateDir = $env:GWM_STATE_DIR
        $script:savedProgramData = $env:ProgramData
        $script:savedLocalAppData = $env:LOCALAPPDATA
        $script:fakeRoot = Join-Path $script:tmp ('gwm-ident-{0}' -f [guid]::NewGuid().ToString('N'))
        $env:GWM_STATE_DIR = $null
        $env:ProgramData = Join-Path $script:fakeRoot 'ProgramData'
        $env:LOCALAPPDATA = Join-Path $script:fakeRoot 'Local'
    }
    AfterEach {
        $env:GWM_STATE_DIR = $script:savedStateDir
        $env:ProgramData = $script:savedProgramData
        $env:LOCALAPPDATA = $script:savedLocalAppData
        Remove-Item -LiteralPath $script:fakeRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'a marker written by a standard user is not listed to SYSTEM, and the reverse' {
        Mock Write-GwmLog { }
        Mock Test-GwmRunningAsSystem { $false }
        Set-GwmReopenOwed -ProcessName 'user-app'
        @(Get-GwmReopenOwed) -join ',' | Should Be 'user-app'

        Mock Test-GwmRunningAsSystem { $true }
        @(Get-GwmReopenOwed).Count | Should Be 0
        Set-GwmReopenOwed -ProcessName 'machine-app'
        @(Get-GwmReopenOwed) -join ',' | Should Be 'machine-app'

        Mock Test-GwmRunningAsSystem { $false }
        @(Get-GwmReopenOwed) -join ',' | Should Be 'user-app'
        Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'wau-graceful-mods\state\reopen-user-app.json') | Should Be $true
        Test-Path -LiteralPath (Join-Path $env:ProgramData 'wau-graceful-mods\state\reopen-machine-app.json') | Should Be $true
    }
}

Describe 'reopen markers' {
    BeforeEach { Use-TempStateDir; $null = Get-GwmStateDir }
    AfterEach { Remove-TempStateDir }

    It 'round-trips a process name' {
        Set-GwmReopenOwed -ProcessName 'fake-app'
        $owed = @(Get-GwmReopenOwed)
        $owed.Count | Should Be 1
        $owed[0] | Should Be 'fake-app'
    }
    It 'writes reopen-<name>.json with process and owedAtUtc' {
        Set-GwmReopenOwed -ProcessName 'fake-app'
        $file = Join-Path $script:stateDir 'reopen-fake-app.json'
        Test-Path -LiteralPath $file | Should Be $true
        $json = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
        $json.process | Should Be 'fake-app'
        $parsed = [datetime]::Parse([string]$json.owedAtUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        $parsed.Kind | Should Be 'Utc'
    }
    It 'returns an empty string array when nothing is owed' {
        $owed = @(Get-GwmReopenOwed)
        $owed.Count | Should Be 0
    }
    It 'returns the names sorted' {
        foreach ($n in 'zeta', 'alpha', 'mid') { Set-GwmReopenOwed -ProcessName $n }
        @(Get-GwmReopenOwed) -join ',' | Should Be 'alpha,mid,zeta'
    }
    It 'is idempotent when the same process is set twice' {
        Set-GwmReopenOwed -ProcessName 'fake-app'
        Set-GwmReopenOwed -ProcessName 'fake-app'
        @(Get-GwmReopenOwed).Count | Should Be 1
    }
    It 'clears one marker and leaves the others' {
        Set-GwmReopenOwed -ProcessName 'one'
        Set-GwmReopenOwed -ProcessName 'two'
        Clear-GwmReopenOwed -ProcessName 'one'
        @(Get-GwmReopenOwed) -join ',' | Should Be 'two'
    }
    It 'clears silently when the marker is absent' {
        { Clear-GwmReopenOwed -ProcessName 'never-set' } | Should Not Throw
        @(Clear-GwmReopenOwed -ProcessName 'never-set').Count | Should Be 0
    }
    It 'ignores and logs a corrupt marker file' {
        Set-GwmReopenOwed -ProcessName 'good'
        Set-Content -LiteralPath (Join-Path $script:stateDir 'reopen-bad.json') -Value '{ not json' -Encoding ASCII
        Mock Write-GwmLog { }
        $owed = @(Get-GwmReopenOwed)
        $owed -join ',' | Should Be 'good'
        Assert-MockCalled Write-GwmLog -Times 1 -ParameterFilter { $Message -like '*reopen-bad.json*' }
    }
    It 'ignores and logs a marker without a process name' {
        Set-Content -LiteralPath (Join-Path $script:stateDir 'reopen-empty.json') -Value '{ "owedAtUtc": "x" }' -Encoding ASCII
        Mock Write-GwmLog { }
        @(Get-GwmReopenOwed).Count | Should Be 0
        Assert-MockCalled Write-GwmLog -Times 1
    }
    It 'ignores and logs a marker whose process name is not a plain file name' {
        Set-Content -LiteralPath (Join-Path $script:stateDir 'reopen-evil.json') -Value '{ "process": "..\\..\\evil", "owedAtUtc": "x" }' -Encoding ASCII
        Mock Write-GwmLog { }
        @(Get-GwmReopenOwed).Count | Should Be 0
        Assert-MockCalled Write-GwmLog -Times 1
    }
    It 'ignores and logs a marker whose process name does not match its file name' {
        Set-Content -LiteralPath (Join-Path $script:stateDir 'reopen-one.json') -Value '{ "process": "two", "owedAtUtc": "x" }' -Encoding ASCII
        Mock Write-GwmLog { }
        @(Get-GwmReopenOwed).Count | Should Be 0
        Assert-MockCalled Write-GwmLog -Times 1
    }
    It 'refuses a process name that would leave the state folder' {
        { Set-GwmReopenOwed -ProcessName '..\evil' } | Should Throw
        { Clear-GwmReopenOwed -ProcessName '..\evil' } | Should Throw
    }
    It 'does not list files that are not reopen markers' {
        Set-Content -LiteralPath (Join-Path $script:stateDir 'other.json') -Value '{ "process": "x" }' -Encoding ASCII
        @(Get-GwmReopenOwed).Count | Should Be 0
    }
}
