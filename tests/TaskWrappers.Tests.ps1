$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$script:closeTask = Join-Path $root 'src\tasks\Invoke-CloseTask.ps1'
$script:openTask = Join-Path $root 'src\tasks\Invoke-OpenTask.ps1'
$script:psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# $env:TEMP can come back in 8.3 form (user~1), which several cmdlets reject; expand it once.
$script:tmp = [System.IO.Path]::GetFullPath($env:TEMP)
$script:tempFiles = @()

function New-TempFile {
    param([string]$Body, [string]$Extension = '.psd1')
    $path = Join-Path $script:tmp ('gwm-test-{0}{1}' -f [guid]::NewGuid().ToString('N'), $Extension)
    Set-Content -LiteralPath $path -Value $Body -Encoding ASCII
    $script:tempFiles += $path
    $path
}

function Remove-TempFiles {
    foreach ($f in $script:tempFiles) {
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
    }
    $script:tempFiles = @()
}

# The wrappers load a library only when its function is missing, so the test defines fakes
# with the contract signatures first. Log.ps1 is loaded here; Manifest.ps1 is left to the close
# wrapper, because its $script: tables must live in the scope of the script that calls it.
. (Join-Path $root 'src\lib\Log.ps1')

function Close-App {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName,
        [string[]]$HiddenWindowClass,
        [int]$TimeoutSec = 30,
        [int]$PollMs = 250
    )
    throw 'the real Close-App must never run in these tests'
}
function Test-GwmProcessRunning {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProcessName)
    throw 'the real Test-GwmProcessRunning must never run in these tests'
}
function Start-Process {
    [CmdletBinding()]
    param([string]$FilePath, [string]$WorkingDirectory)
    throw 'the real Start-Process must never run in these tests'
}

function New-CloseResult {
    param([string]$ProcessName, [bool]$Exited)
    [pscustomobject]@{ ProcessName = $ProcessName; Found = $true; Exited = $Exited; Reason = $(if ($Exited) { 'exited' } else { 'timeout' }) }
}

Describe 'Invoke-CloseTask.ps1' {
    AfterEach { Remove-TempFiles }

    Context 'with a manifest' {
        BeforeEach {
            $script:proc = 'gwm-fake-' + [guid]::NewGuid().ToString('N')
            $script:manifest = New-TempFile ("@{ Apps = @(" +
                " @{ Id='Fake.Tray'; Process='$($script:proc)'; Scope='machine'; Policy='close-reopen'; Exe=@('C:\fake\a.exe'); HiddenWindowClass=@('Qt*Fake','Other*') }," +
                " @{ Id='Fake.Plain'; Process='$($script:proc)-plain'; Scope='machine'; Policy='close-reopen'; Exe=@('C:\fake\b.exe') } ) }")
        }

        It 'passes the process name, the timeout and the hidden window classes of the app to Close-App' {
            Mock Close-App { New-CloseResult $ProcessName $true }
            Mock Close-App { New-CloseResult $ProcessName $true }
            $script:upper = $script:proc.ToUpperInvariant()
            & $script:closeTask -ProcessName $script:upper -TimeoutSec 17 -ManifestPath $script:manifest
            $LASTEXITCODE | Should Be 0
            Assert-MockCalled Close-App -Exactly -Times 1 -ParameterFilter {
                $ProcessName -eq $script:upper -and $TimeoutSec -eq 17 -and
                ($HiddenWindowClass -join '|') -eq 'Qt*Fake|Other*'
            }
        }
        It 'adds no hidden window class for an app that has none' {
            Mock Close-App { New-CloseResult $ProcessName $true }
            & $script:closeTask -ProcessName ($script:proc + '-plain') -ManifestPath $script:manifest
            $LASTEXITCODE | Should Be 0
            Assert-MockCalled Close-App -Exactly -Times 1 -ParameterFilter { $ProcessName -eq ($script:proc + '-plain') -and -not $HiddenWindowClass }
        }
        It 'closes an app the manifest does not list, without hidden window classes' {
            Mock Close-App { New-CloseResult $ProcessName $true }
            $other = 'gwm-fake-' + [guid]::NewGuid().ToString('N')
            & $script:closeTask -ProcessName $other -ManifestPath $script:manifest
            $LASTEXITCODE | Should Be 0
            Assert-MockCalled Close-App -Exactly -Times 1 -ParameterFilter { $ProcessName -eq $other -and -not $HiddenWindowClass }
        }
        It 'defaults the timeout to 30 seconds' {
            Mock Close-App { New-CloseResult $ProcessName $true }
            & $script:closeTask -ProcessName $script:proc -ManifestPath $script:manifest
            Assert-MockCalled Close-App -Exactly -Times 1 -ParameterFilter { $ProcessName -eq $script:proc -and $TimeoutSec -eq 30 }
        }
        It 'exits 1 when the process did not exit' {
            Mock Close-App { New-CloseResult $ProcessName $false }
            & $script:closeTask -ProcessName $script:proc -ManifestPath $script:manifest
            $LASTEXITCODE | Should Be 1
        }
        It 'exits 1 when Close-App throws' {
            Mock Close-App { throw 'boom' }
            & $script:closeTask -ProcessName $script:proc -ManifestPath $script:manifest
            $LASTEXITCODE | Should Be 1
        }
    }

    Context 'without a usable manifest' {
        It 'goes ahead without hidden window classes when the manifest is missing' {
            Mock Close-App { New-CloseResult $ProcessName $true }
            $proc = 'gwm-fake-' + [guid]::NewGuid().ToString('N')
            & $script:closeTask -ProcessName $proc -ManifestPath (Join-Path $script:tmp ('gwm-missing-{0}.psd1' -f [guid]::NewGuid().ToString('N')))
            $LASTEXITCODE | Should Be 0
            Assert-MockCalled Close-App -Exactly -Times 1 -ParameterFilter { $ProcessName -eq $proc -and -not $HiddenWindowClass }
        }
        It 'goes ahead without hidden window classes when the manifest is unreadable' {
            Mock Close-App { New-CloseResult $ProcessName $true }
            $proc = 'gwm-fake-' + [guid]::NewGuid().ToString('N')
            $bad = New-TempFile 'this is { not a manifest'
            & $script:closeTask -ProcessName $proc -ManifestPath $bad
            $LASTEXITCODE | Should Be 0
            Assert-MockCalled Close-App -Exactly -Times 1 -ParameterFilter { $ProcessName -eq $proc -and -not $HiddenWindowClass }
        }
        It 'still reports a failed close as exit 1 without a manifest' {
            Mock Close-App { New-CloseResult $ProcessName $false }
            & $script:closeTask -ProcessName ('gwm-fake-' + [guid]::NewGuid().ToString('N')) -ManifestPath (Join-Path $script:tmp 'gwm-missing-manifest.psd1')
            $LASTEXITCODE | Should Be 1
        }
    }
}

Describe 'Invoke-OpenTask.ps1' {
    Context 'with faked process lookup and launcher' {
        # A file of its own per test: Start-ScheduledTask-style mocks keep their call history across
        # tests, so the exe path is what tells one test's calls from another's. Start-Process is faked.
        BeforeEach {
            $script:proc = 'gwm-fake-' + [guid]::NewGuid().ToString('N')
            $script:exe = New-TempFile 'not a real program' '.exe'
        }
        AfterEach { Remove-TempFiles }

        It 'starts the exe and exits 0 when the process is not running' {
            Mock Test-GwmProcessRunning { $false }
            Mock Start-Process { }
            & $script:openTask -ProcessName $script:proc -ExePath $script:exe
            $LASTEXITCODE | Should Be 0
            Assert-MockCalled Start-Process -Exactly -Times 1 -ParameterFilter { $FilePath -eq $script:exe }
        }
        It 'checks the process by name' {
            Mock Test-GwmProcessRunning { $false }
            Mock Start-Process { }
            & $script:openTask -ProcessName $script:proc -ExePath $script:exe
            Assert-MockCalled Test-GwmProcessRunning -Exactly -Times 1 -ParameterFilter { $ProcessName -eq $script:proc }
        }
        It 'starts nothing and exits 0 when the process already runs' {
            Mock Test-GwmProcessRunning { $true }
            Mock Start-Process { }
            & $script:openTask -ProcessName $script:proc -ExePath $script:exe
            $LASTEXITCODE | Should Be 0
            Assert-MockCalled Start-Process -Exactly -Times 0 -ParameterFilter { $FilePath -eq $script:exe }
        }
        It 'exits 2 and starts nothing when the exe does not exist' {
            Mock Test-GwmProcessRunning { $false }
            Mock Start-Process { }
            $missing = Join-Path $script:tmp ('gwm-missing-{0}.exe' -f [guid]::NewGuid().ToString('N'))
            & $script:openTask -ProcessName $script:proc -ExePath $missing
            $LASTEXITCODE | Should Be 2
            Assert-MockCalled Start-Process -Exactly -Times 0 -ParameterFilter { $FilePath -eq $missing }
        }
        It 'exits 3 when starting the exe throws' {
            Mock Test-GwmProcessRunning { $false }
            Mock Start-Process { throw 'cannot start' }
            & $script:openTask -ProcessName $script:proc -ExePath $script:exe
            $LASTEXITCODE | Should Be 3
        }
    }
}

Describe 'the wrappers as real scripts' {
    # A child Windows PowerShell loads the real libraries from ..\lib and returns a real exit code.
    function Invoke-Wrapper {
        param([string]$Script, [string[]]$Arguments)
        & $script:psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Script @Arguments | Out-Null
        $LASTEXITCODE
    }

    It 'the close wrapper exits 0 for a process that is not running' {
        $proc = 'gwm-fake-' + [guid]::NewGuid().ToString('N')
        Invoke-Wrapper $script:closeTask @('-ProcessName', $proc, '-TimeoutSec', '5') | Should Be 0
    }
    It 'the open wrapper exits 2 for an exe that does not exist' {
        $proc = 'gwm-fake-' + [guid]::NewGuid().ToString('N')
        $missing = Join-Path $script:tmp ('gwm-missing-{0}.exe' -f [guid]::NewGuid().ToString('N'))
        Invoke-Wrapper $script:openTask @('-ProcessName', $proc, '-ExePath', $missing) | Should Be 2
    }
}
