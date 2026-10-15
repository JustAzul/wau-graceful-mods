$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'src\lib\Log.ps1')
. (Join-Path $root 'src\lib\CloseApp.ps1')
. (Join-Path $here 'fixtures\Fixture.ps1')

function Measure-Close {
    param([string]$Name, [int]$TimeoutSec = 10)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $result = Close-App -ProcessName $Name -TimeoutSec $TimeoutSec
    $sw.Stop()
    [pscustomobject]@{ Result = $result; Seconds = $sw.Elapsed.TotalSeconds }
}

function New-RunningFixture {
    param([string]$Mode, [string]$Name, [string]$Kind = 'raw')
    if ($Name) { $fx = New-GwmFixture -Mode $Mode -Kind $Kind -Name $Name } else { $fx = New-GwmFixture -Mode $Mode -Kind $Kind }
    Start-GwmFixture -Fixture $fx | Out-Null
    $fx
}

function Wait-FixtureExit {
    param($Fixture, [int]$Seconds = 5)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ((Test-GwmFixtureAlive -Fixture $Fixture) -and $sw.Elapsed.TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 100
    }
}

Describe 'Close-App' {
    AfterEach { Remove-GwmFixtures }

    Context 'process not running' {
        It 'reports not-running and returns fast' {
            $name = 'gwm-fixture-' + [guid]::NewGuid().ToString('N')
            $m = Measure-Close -Name $name
            @($m.Result).Count | Should Be 1
            $m.Result.ProcessName | Should Be $name
            $m.Result.Found | Should Be $false
            $m.Result.Exited | Should Be $true
            $m.Result.Reason | Should Be 'not-running'
            $m.Seconds | Should BeLessThan 2
        }
    }

    Context 'an app that exits when closed' {
        It 'exits through its own close handler' {
            $fx = New-RunningFixture -Mode 'exit'
            $m = Measure-Close -Name $fx.Name
            @($m.Result).Count | Should Be 1
            $m.Result.Found | Should Be $true
            $m.Result.Exited | Should Be $true
            $m.Result.Reason | Should Be 'exited'
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $false
            # The marker is written by the FormClosing handler: the app left by itself.
            (Get-GwmFixtureMarker -Fixture $fx) -contains 'closing' | Should Be $true
        }
        It 'matches the process name ignoring case' {
            $fx = New-RunningFixture -Mode 'exit'
            $r = Close-App -ProcessName $fx.Name.ToUpperInvariant() -TimeoutSec 10
            $r.Found | Should Be $true
            $r.Reason | Should Be 'exited'
        }
        It 'can be called again in the same session once the app is gone' {
            $fx = New-RunningFixture -Mode 'exit'
            (Close-App -ProcessName $fx.Name -TimeoutSec 10).Reason | Should Be 'exited'
            (Close-App -ProcessName $fx.Name -TimeoutSec 10).Reason | Should Be 'not-running'
        }
    }

    Context 'an app that cancels the close' {
        It 'times out within the timeout and the process is still alive' {
            $fx = New-RunningFixture -Mode 'ignore'
            $m = Measure-Close -Name $fx.Name -TimeoutSec 3
            @($m.Result).Count | Should Be 1
            $m.Result.Found | Should Be $true
            $m.Result.Exited | Should Be $false
            $m.Result.Reason | Should Be 'timeout'
            $m.Seconds | Should BeLessThan 6
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
            # The fixture saw the close request and refused it: the timeout is not a no-op.
            (Get-GwmFixtureMarker -Fixture $fx) -contains 'close-attempt' | Should Be $true
        }
        It 'respects the TimeoutSec parameter' {
            $fx = New-RunningFixture -Mode 'ignore'
            $m = Measure-Close -Name $fx.Name -TimeoutSec 2
            $m.Result.Reason | Should Be 'timeout'
            $m.Seconds | Should BeGreaterThan 1.8
            $m.Seconds | Should BeLessThan 5
        }
    }

    Context 'an app with a hidden window' {
        It 'exits on close although its window is never shown' {
            $fx = New-RunningFixture -Mode 'hidden'
            # Proves the premise: no visible top-level window, so CloseMainWindow could not work.
            $fx.Process.Refresh()
            [int64]$fx.Process.MainWindowHandle | Should Be 0
            $r = Close-App -ProcessName $fx.Name -HiddenWindowClass 'GwmFixtureWindow' -TimeoutSec 10
            $r.Found | Should Be $true
            $r.Exited | Should Be $true
            $r.Reason | Should Be 'exited'
            (Get-GwmFixtureMarker -Fixture $fx) -contains 'closing' | Should Be $true
        }
    }

    Context 'a close-to-tray app' {
        It 'is closed a second time after it hides its window' {
            $fx = New-RunningFixture -Mode 'tray'
            $r = Close-App -ProcessName $fx.Name -HiddenWindowClass 'GwmFixtureWindow' -TimeoutSec 10
            $r.Found | Should Be $true
            $r.Exited | Should Be $true
            $r.Reason | Should Be 'exited'
            ((Get-GwmFixtureMarker -Fixture $fx) -join ',') | Should Be 'close-1-hide,close-2-exit'
        }
    }

    Context 'hidden windows are opt-in by class (raw windows)' {
        It 'leaves a hidden window alone when no class is given' {
            $fx = New-RunningFixture -Mode 'hidden'
            $r = Close-App -ProcessName $fx.Name -TimeoutSec 2
            $r.Reason | Should Be 'timeout'
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
            @(Get-GwmFixtureMarker -Fixture $fx).Count | Should Be 0
        }
        It 'leaves a hidden window alone when its class matches no pattern' {
            $fx = New-RunningFixture -Mode 'hidden'
            $r = Close-App -ProcessName $fx.Name -HiddenWindowClass 'Other*', 'GwmFixture' -TimeoutSec 2
            $r.Reason | Should Be 'timeout'
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
            @(Get-GwmFixtureMarker -Fixture $fx).Count | Should Be 0
        }
        It 'matches the class with -like, ignoring case' {
            $fx = New-RunningFixture -Mode 'hidden'
            $r = Close-App -ProcessName $fx.Name -HiddenWindowClass 'gwmfixture*' -TimeoutSec 10
            $r.Reason | Should Be 'exited'
            (Get-GwmFixtureMarker -Fixture $fx) -contains 'closing' | Should Be $true
        }
        It 'does not close a close-to-tray window a second time without a class' {
            $fx = New-RunningFixture -Mode 'tray'
            $r = Close-App -ProcessName $fx.Name -TimeoutSec 2
            $r.Reason | Should Be 'timeout'
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
            ((Get-GwmFixtureMarker -Fixture $fx) -join ',') | Should Be 'close-1-hide'
        }
        It 'closes only the matching hidden main window, not other hidden windows' {
            $fx = New-RunningFixture -Mode 'decoys'
            $r = Close-App -ProcessName $fx.Name -HiddenWindowClass 'GwmFixtureWindow' -TimeoutSec 2
            $r.Reason | Should Be 'timeout'
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
            $marker = @(Get-GwmFixtureMarker -Fixture $fx)
            ($marker -contains 'close-attempt') | Should Be $true
            # No decoy (other class, untitled, owned) may have received WM_CLOSE.
            @($marker | Where-Object { $_ -like 'decoy-closed:*' }).Count | Should Be 0
        }
    }

    Context 'real WinForms processes with the framework helper windows' {
        It 'has a helper window whose WM_CLOSE ends the process without the close handler (premise)' {
            $fx = New-RunningFixture -Mode 'ignore' -Kind 'winforms'
            Initialize-GwmWindowApi
            $helpers = @([GwmNative.CloseAppWindows]::GetWindows([uint32]$fx.Process.Id) |
                Where-Object { [GwmNative.CloseAppWindows]::GetClassName($_) -like 'WindowsForms10.Window.0.*' })
            $helpers.Count | Should BeGreaterThan 0
            [void][GwmNative.CloseAppWindows]::PostClose($helpers[0])
            Wait-FixtureExit -Fixture $fx
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $false
            @(Get-GwmFixtureMarker -Fixture $fx).Count | Should Be 0
        }
        It 'runs the FormClosing handler of a form that exits' {
            $fx = New-RunningFixture -Mode 'exit' -Kind 'winforms'
            $r = Close-App -ProcessName $fx.Name -TimeoutSec 10
            $r.Reason | Should Be 'exited'
            (Get-GwmFixtureMarker -Fixture $fx) -contains 'closing' | Should Be $true
        }
        It 'lets a form cancel the close: handler runs, process stays alive' {
            $fx = New-RunningFixture -Mode 'ignore' -Kind 'winforms'
            $r = Close-App -ProcessName $fx.Name -TimeoutSec 3
            $r.Reason | Should Be 'timeout'
            $r.Exited | Should Be $false
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
            (Get-GwmFixtureMarker -Fixture $fx) -contains 'close-attempt' | Should Be $true
        }
        It 'leaves a hidden main window alone when no class is given' {
            $fx = New-RunningFixture -Mode 'hidden-exit' -Kind 'winforms'
            $r = Close-App -ProcessName $fx.Name -TimeoutSec 2
            $r.Reason | Should Be 'timeout'
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
            @(Get-GwmFixtureMarker -Fixture $fx).Count | Should Be 0
        }
        It 'closes a hidden tray-style main window gracefully when its class is named' {
            $fx = New-RunningFixture -Mode 'hidden-exit' -Kind 'winforms'
            $r = Close-App -ProcessName $fx.Name -HiddenWindowClass 'WindowsForms10.Window.8.*' -TimeoutSec 10
            $r.Reason | Should Be 'exited'
            (Get-GwmFixtureMarker -Fixture $fx) -contains 'closing' | Should Be $true
        }
        It 'does not touch the hidden helper windows when it closes the matching main window' {
            $fx = New-RunningFixture -Mode 'hidden-ignore' -Kind 'winforms'
            $r = Close-App -ProcessName $fx.Name -HiddenWindowClass 'WindowsForms10.Window.8.*' -TimeoutSec 3
            $r.Reason | Should Be 'timeout'
            # The handler ran (so the main window was targeted) and the process survived (so the
            # parking window, which would have ended it, was not).
            (Get-GwmFixtureMarker -Fixture $fx) -contains 'close-attempt' | Should Be $true
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
        }
        It 'closes a WinForms close-to-tray form a second time once it is hidden and its class is named' {
            $fx = New-RunningFixture -Mode 'tray' -Kind 'winforms'
            $r = Close-App -ProcessName $fx.Name -HiddenWindowClass 'WindowsForms10.Window.8.*' -TimeoutSec 10
            $r.Reason | Should Be 'exited'
            ((Get-GwmFixtureMarker -Fixture $fx) -join ',') | Should Be 'close-1-hide,close-2-exit'
        }
        It 'does not close that tray form a second time without the class' {
            $fx = New-RunningFixture -Mode 'tray' -Kind 'winforms'
            $r = Close-App -ProcessName $fx.Name -TimeoutSec 2
            $r.Reason | Should Be 'timeout'
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
            ((Get-GwmFixtureMarker -Fixture $fx) -join ',') | Should Be 'close-1-hide'
        }
    }

    Context 'strict mode' {
        It 'runs under Set-StrictMode -Version 2 for a running and a missing process' {
            $fx = New-RunningFixture -Mode 'tray'
            Set-StrictMode -Version 2
            try {
                (Close-App -ProcessName $fx.Name -HiddenWindowClass 'GwmFixtureWindow' -TimeoutSec 10).Reason | Should Be 'exited'
                (Close-App -ProcessName $fx.Name -HiddenWindowClass 'GwmFixtureWindow' -TimeoutSec 10).Reason | Should Be 'not-running'
            }
            finally {
                Set-StrictMode -Off
            }
        }
    }

    Context 'name matching is exact' {
        It 'leaves a process whose name only starts with the target name untouched' {
            $target = New-RunningFixture -Mode 'exit'
            $longer = New-RunningFixture -Mode 'exit' -Name ($target.Name + 'x')
            $r = Close-App -ProcessName $target.Name -TimeoutSec 10
            $r.Reason | Should Be 'exited'
            (Test-GwmFixtureAlive -Fixture $target) | Should Be $false
            (Test-GwmFixtureAlive -Fixture $longer) | Should Be $true
            @(Get-GwmFixtureMarker -Fixture $longer).Count | Should Be 0
        }
        It 'does not treat the name as a wildcard pattern' {
            $fx = New-RunningFixture -Mode 'exit'
            $r = Close-App -ProcessName ($fx.Name.Substring(0, $fx.Name.Length - 4) + '*') -TimeoutSec 2
            $r.Found | Should Be $false
            (Test-GwmFixtureAlive -Fixture $fx) | Should Be $true
        }
    }
}
