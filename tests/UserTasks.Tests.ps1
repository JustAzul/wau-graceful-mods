$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'src\lib\Log.ps1')
. (Join-Path $root 'src\lib\Manifest.ps1')
. (Join-Path $root 'src\lib\Process.ps1')
. (Join-Path $root 'src\lib\UserTasks.ps1')

$script:mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$script:psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function New-FakeApp {
    param([string]$Process = 'fake-app', [string]$Scope = 'machine', [string]$Policy = 'close-reopen', [string[]]$Exe = @())
    @{ Id = 'Fake.' + $Process; Process = $Process; Scope = $Scope; Policy = $Policy; Exe = $Exe }
}

$script:madeFolders = @()

function New-TestFolder {
    $folder = '\wau-gm-test-{0}\' -f [guid]::NewGuid().ToString('N')
    $script:madeFolders += $folder
    $folder
}

# Removes every task in a throwaway folder (stopping running ones) and then the folder itself.
# It talks to the Schedule.Service COM object directly, so a faked ScheduledTasks cmdlet cannot
# make it skip the cleanup. It refuses any folder that this file did not create.
function Remove-TestFolder {
    param([string]$Folder)
    if (-not $Folder -or $Folder -notlike '\wau-gm-test-*' -or $script:madeFolders -notcontains $Folder) { return }
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    try { $folderObject = $svc.GetFolder($Folder.TrimEnd('\')) } catch { return }
    foreach ($task in @($folderObject.GetTasks(1))) {
        try { $task.Stop(0) } catch { }
        $folderObject.DeleteTask($task.Name, 0)
    }
    $svc.GetFolder('\').DeleteFolder($Folder.Trim('\'), 0)
}

# True when the scheduler still has this folder.
function Test-TestFolderExists {
    param([string]$Folder)
    $svc = New-Object -ComObject Schedule.Service
    $svc.Connect()
    try { $null = $svc.GetFolder($Folder.TrimEnd('\')); $true } catch { $false }
}

# Task read back from the scheduler, or $null. A task that was only just registered can be read
# back half-filled for a moment on a busy machine, so wait for the fields the tests look at.
function Get-TestTask {
    param([string]$Folder, [string]$Name)
    $task = $null
    for ($try = 0; $try -lt 10; $try++) {
        $task = Get-ScheduledTask -TaskPath $Folder -TaskName $Name -ErrorAction SilentlyContinue
        if ($task -and $task.Actions -and $task.Principal.UserId) { return $task }
        Start-Sleep -Milliseconds 200
    }
    $task
}

# Registers a throwaway task named like a real one (<Process>-<action>) whose action runs a
# hidden console command instead of the real wrapper, so nothing appears on the desktop.
function New-TestTask {
    param([string]$Folder, [string]$Process, [string]$Action, [string]$Command)
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $a = New-ScheduledTaskAction -Execute $conhost -Argument ('--headless cmd.exe /c ' + $Command)
    $p = New-ScheduledTaskPrincipal -UserId $script:mySid -LogonType Interactive -RunLevel Limited
    $st = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    Register-ScheduledTask -TaskPath $Folder -TaskName ('{0}-{1}' -f $Process, $Action) -Action $a -Principal $p -Settings $st -Force | Out-Null
}

Describe 'Get-GwmTaskName' {
    It 'joins the process name and the action' {
        Get-GwmTaskName -App (New-FakeApp -Process 'qbittorrent') -Action close | Should Be 'qbittorrent-close'
        Get-GwmTaskName -App (New-FakeApp -Process 'MailClient') -Action open | Should Be 'MailClient-open'
    }
    It 'rejects an unknown action' {
        { Get-GwmTaskName -App (New-FakeApp) -Action nuke } | Should Throw
    }
}

Describe 'New-GwmTaskSpec' {
    $app = New-FakeApp -Process 'fake-app'
    $common = @{ App = $app; UserSid = 'S-1-5-21-1-2-3-1001'; TasksDir = 'C:\fake\gwm\tasks'; TaskFolder = '\wau-graceful-mods\' }

    It 'returns exactly the documented fields' {
        $spec = New-GwmTaskSpec @common -Action close
        $names = @($spec.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
        ($names -join ',') | Should Be 'Arguments,Execute,ExecutionTimeLimit,LogonType,MultipleInstances,RunLevel,TaskName,TaskPath,UserSid'
    }
    It 'names the close task and builds its arguments with the timeout' {
        $spec = New-GwmTaskSpec @common -Action close -TimeoutSec 45
        $spec.TaskPath | Should Be '\wau-graceful-mods\'
        $spec.TaskName | Should Be 'fake-app-close'
        $spec.Arguments | Should Be '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\fake\gwm\tasks\Invoke-CloseTask.ps1" -ProcessName "fake-app" -TimeoutSec 45'
    }
    It 'defaults the close timeout to 60 seconds' {
        (New-GwmTaskSpec @common -Action close).Arguments | Should Match ' -TimeoutSec 60$'
    }
    It 'never defaults the close timeout below 60 seconds, so the wrapper outlasts the caller' {
        $spec = New-GwmTaskSpec @common -Action close
        $spec.Arguments -match ' -TimeoutSec (\d+)$' | Should Be $true
        [int]$Matches[1] | Should Not BeLessThan 60
    }
    It 'gives the default close task a 120 second execution limit' {
        (New-GwmTaskSpec @common -Action close).ExecutionTimeLimit.TotalSeconds | Should Be 120
    }
    It 'builds the open arguments with the exe path' {
        $spec = New-GwmTaskSpec @common -Action open -ExePath 'C:\Program Files\Fake\fake.exe'
        $spec.TaskName | Should Be 'fake-app-open'
        $spec.Arguments | Should Be '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "C:\fake\gwm\tasks\Invoke-OpenTask.ps1" -ProcessName "fake-app" -ExePath "C:\Program Files\Fake\fake.exe"'
    }
    It 'uses the full path of Windows PowerShell 5.1' {
        (New-GwmTaskSpec @common -Action close).Execute | Should Be ($env:SystemRoot + '\System32\WindowsPowerShell\v1.0\powershell.exe')
    }
    It 'runs as the given user, interactive, limited, one instance at a time' {
        $spec = New-GwmTaskSpec @common -Action close
        $spec.UserSid | Should Be 'S-1-5-21-1-2-3-1001'
        $spec.LogonType | Should Be 'Interactive'
        $spec.RunLevel | Should Be 'Limited'
        $spec.MultipleInstances | Should Be 'IgnoreNew'
        $spec.ExecutionTimeLimit.GetType().FullName | Should Be 'System.TimeSpan'
        $spec.ExecutionTimeLimit.TotalSeconds | Should BeGreaterThan 30
    }
    It 'gives the close task a time limit that covers its timeout' {
        $spec = New-GwmTaskSpec @common -Action close -TimeoutSec 120
        $spec.ExecutionTimeLimit.TotalSeconds | Should BeGreaterThan 120
    }
    It 'normalizes the task folder to leading and trailing backslashes' {
        (New-GwmTaskSpec @common -Action close).TaskPath | Should Be '\wau-graceful-mods\'
        $c2 = @{} + $common; $c2.TaskFolder = 'wau-graceful-mods'
        (New-GwmTaskSpec @c2 -Action close).TaskPath | Should Be '\wau-graceful-mods\'
    }
    It 'requires an exe path for the open task' {
        { New-GwmTaskSpec @common -Action open } | Should Throw 'ExePath'
    }
    It 'refuses values that would break the quoted command line' {
        $c3 = @{} + $common; $c3.App = New-FakeApp -Process 'bad"name'
        { New-GwmTaskSpec @c3 -Action close } | Should Throw 'quote'
        { New-GwmTaskSpec @common -Action open -ExePath 'C:\x"y.exe' } | Should Throw 'quote'
    }
    It 'is pure: touches no scheduler' {
        Mock Register-ScheduledTask { }
        Mock Get-ScheduledTask { }
        New-GwmTaskSpec @common -Action close | Out-Null
        Assert-MockCalled Register-ScheduledTask -Exactly -Times 0
        Assert-MockCalled Get-ScheduledTask -Exactly -Times 0
    }
}

Describe 'Register-GwmTasks and Unregister-GwmTasks' {
    $cmdExe = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $tasksDir = 'C:\fake\gwm\tasks'

    Context 'registration' {
        $folder = $null
        BeforeEach { $script:folder = New-TestFolder }
        AfterEach { Remove-TestFolder $script:folder }

        It 'registers the close and open task of a machine close-reopen app and returns their specs' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            $specs = @(Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder)
            $specs.Count | Should Be 2
            (($specs | ForEach-Object { $_.TaskName } | Sort-Object) -join ',') | Should Be 'gwm-fake-a-close,gwm-fake-a-open'
            $tasks = @(Get-ScheduledTask -TaskPath $script:folder)
            (($tasks | ForEach-Object { $_.TaskName } | Sort-Object) -join ',') | Should Be 'gwm-fake-a-close,gwm-fake-a-open'
        }
        It 'creates tasks that run as the user, interactive, limited, with no trigger' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder | Out-Null
            foreach ($name in 'gwm-fake-a-close', 'gwm-fake-a-open') {
                $t = Get-TestTask $script:folder $name
                $uid = [string]$t.Principal.UserId
                if ($uid -notmatch '^S-1-') {
                    $uid = (New-Object System.Security.Principal.NTAccount($uid)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                }
                $uid | Should Be $script:mySid
                [string]$t.Principal.LogonType | Should Be 'Interactive'
                [string]$t.Principal.RunLevel | Should Be 'Limited'
                [string]$t.Settings.MultipleInstances | Should Be 'IgnoreNew'
                @($t.Triggers | Where-Object { $_ }).Count | Should Be 0
                $t.Settings.DisallowStartIfOnBatteries | Should Be $false
                $t.Settings.StopIfGoingOnBatteries | Should Be $false
                [string]$t.State | Should Be 'Ready'
            }
        }
        It 'gives each task the action from its spec' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            $specs = @(Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder)
            foreach ($spec in $specs) {
                $t = Get-TestTask $script:folder $spec.TaskName
                $t.Actions[0].Execute | Should Be $spec.Execute
                $t.Actions[0].Arguments | Should Be $spec.Arguments
                $t.Settings.ExecutionTimeLimit | Should Be ([System.Xml.XmlConvert]::ToString($spec.ExecutionTimeLimit))
            }
        }
        It 'registers the close task with the default 60 second timeout and a 120 second limit' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder | Out-Null
            $t = Get-TestTask $script:folder 'gwm-fake-a-close'
            $t.Actions[0].Arguments | Should Match ' -TimeoutSec 60$'
            $t.Settings.ExecutionTimeLimit | Should Be 'PT2M'
        }
        It 'passes the exe it resolved to the open task' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder | Out-Null
            (Get-TestTask $script:folder 'gwm-fake-a-open').Actions[0].Arguments | Should Match ([regex]::Escape('-ExePath "' + $cmdExe + '"'))
        }
        It 'skips apps that are not machine-scope close-reopen' {
            $apps = @(
                (New-FakeApp -Process 'gwm-fake-user' -Scope 'user' -Exe @($cmdExe)),
                (New-FakeApp -Process 'gwm-fake-skip' -Policy 'skip-if-open'),
                (New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe))
            )
            $specs = @(Register-GwmTasks -Apps $apps -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder)
            $specs.Count | Should Be 2
            (@(Get-ScheduledTask -TaskPath $script:folder | ForEach-Object { $_.TaskName } | Sort-Object) -join ',') | Should Be 'gwm-fake-a-close,gwm-fake-a-open'
        }
        It 'is idempotent and replaces a task that already exists' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder | Out-Null
            Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir 'C:\fake\other\tasks' -TaskFolder $script:folder | Out-Null
            @(Get-ScheduledTask -TaskPath $script:folder).Count | Should Be 2
            (Get-TestTask $script:folder 'gwm-fake-a-close').Actions[0].Arguments | Should Match ([regex]::Escape('C:\fake\other\tasks'))
        }
        It 'skips the open task and logs when the exe cannot be resolved' {
            Mock Write-GwmLog { }
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @('C:\gwm-does-not-exist\nope.exe')
            $specs = @(Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder)
            $specs.Count | Should Be 1
            $specs[0].TaskName | Should Be 'gwm-fake-a-close'
            (Get-TestTask $script:folder 'gwm-fake-a-open') | Should BeNullOrEmpty
            Assert-MockCalled Write-GwmLog -ParameterFilter { $Message -match 'No executable found for gwm-fake-a' } -Exactly -Times 1
        }
        It 'hands the user context to Resolve-GwmExe' {
            $ctx = [pscustomobject]@{ UserSid = $script:mySid; ProfilePath = 'C:\Users\fake-user' }
            Mock Resolve-GwmExe { $cmdExe }
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @('%APPDATA%\x.exe')
            Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder -UserContext $ctx | Out-Null
            Assert-MockCalled Resolve-GwmExe -ParameterFilter { $UserContext.ProfilePath -eq 'C:\Users\fake-user' } -Times 1
        }
    }

    Context 'removal' {
        $folder = $null
        BeforeEach { $script:folder = New-TestFolder }
        AfterEach { Remove-TestFolder $script:folder }

        It 'removes the tasks of the given apps and nothing else' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            $other = New-FakeApp -Process 'gwm-fake-b' -Exe @($cmdExe)
            Register-GwmTasks -Apps @($app, $other) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder | Out-Null
            Unregister-GwmTasks -Apps @($app) -TaskFolder $script:folder
            (@(Get-ScheduledTask -TaskPath $script:folder | ForEach-Object { $_.TaskName } | Sort-Object) -join ',') | Should Be 'gwm-fake-b-close,gwm-fake-b-open'
        }
        It 'is silent when nothing exists, folder included' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            $out = @(Unregister-GwmTasks -Apps @($app) -TaskFolder $script:folder 2>&1)
            $out.Count | Should Be 0
        }
        It 'is silent when only some of the tasks exist' {
            $app = New-FakeApp -Process 'gwm-fake-a' -Exe @($cmdExe)
            Register-GwmTasks -Apps @($app) -UserSid $script:mySid -TasksDir $tasksDir -TaskFolder $script:folder | Out-Null
            Unregister-ScheduledTask -TaskPath $script:folder -TaskName 'gwm-fake-a-open' -Confirm:$false
            $out = @(Unregister-GwmTasks -Apps @($app) -TaskFolder $script:folder 2>&1)
            $out.Count | Should Be 0
            @(Get-ScheduledTask -TaskPath $script:folder -ErrorAction SilentlyContinue).Count | Should Be 0
        }
    }
}

Describe 'Unregister-GwmTasks failures' {
    It 'does not swallow a removal that fails while the task is still there' {
        Mock Unregister-ScheduledTask { throw 'access denied' }
        Mock Get-ScheduledTask { [pscustomobject]@{ TaskName = 'gwm-fake-z-close' } }
        $app = New-FakeApp -Process 'gwm-fake-z' -Exe @((Join-Path $env:SystemRoot 'System32\cmd.exe'))
        { Unregister-GwmTasks -Apps @($app) -TaskFolder '\wau-gm-test-never-created\' } | Should Throw 'access denied'
    }
}

Describe 'Test-GwmInteractiveSession' {
    It 'is true when an explorer process exists' {
        Mock Get-Process { [pscustomobject]@{ Name = 'explorer' } }
        $r = Test-GwmInteractiveSession
        $r | Should Be $true
        $r.GetType().FullName | Should Be 'System.Boolean'
        Assert-MockCalled Get-Process -ParameterFilter { $Name -eq 'explorer' } -Times 1
    }
    It 'is false when there is none' {
        Mock Get-Process { $null }
        Test-GwmInteractiveSession | Should Be $false
    }
}

Describe 'Invoke-GwmTask' {
    $script:folder = $null

    # Pester 3.4 keeps a Mock alive until its enclosing Describe/Context ends, so the tests that
    # need the real Start-ScheduledTask live in a Context of their own, ahead of the faked ones.
    Context 'against the real scheduler' {
        BeforeEach {
            $script:folder = New-TestFolder
            $script:app = New-FakeApp -Process ('gwm-fake-' + [guid]::NewGuid().ToString('N'))
            Mock Test-GwmInteractiveSession { $true }
        }
        AfterEach { Remove-TestFolder $script:folder }

        It 'runs the task and reports done with the task result' {
            New-TestTask $script:folder $script:app.Process 'close' 'exit 0'
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder -TimeoutSec 20
            $r.Started | Should Be $true
            $r.Completed | Should Be $true
            $r.Result | Should Be 0
            $r.Reason | Should Be 'done'
        }
        It 'returns exactly one object with the documented fields' {
            New-TestTask $script:folder $script:app.Process 'close' 'exit 0'
            $r = @(Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder -TimeoutSec 20)
            $r.Count | Should Be 1
            (@($r[0].PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object) -join ',') | Should Be 'Completed,Reason,Result,Started'
        }
        It 'does not start a task that is already running' {
            $name = $script:app.Process + '-close'
            New-TestTask $script:folder $script:app.Process 'close' 'ping -n 60 127.0.0.1 >nul'
            Start-ScheduledTask -TaskPath $script:folder -TaskName $name
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-TestTask $script:folder $name).State -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            [string](Get-TestTask $script:folder $name).State | Should Be 'Running'
            $before = (Get-ScheduledTaskInfo -TaskPath $script:folder -TaskName $name).LastRunTime
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder
            $r.Started | Should Be $false
            $r.Reason | Should Be 'not-ready'
            (Get-ScheduledTaskInfo -TaskPath $script:folder -TaskName $name).LastRunTime | Should Be $before
        }
        It 'times out, stops the task and reports Completed false' {
            $name = $script:app.Process + '-close'
            New-TestTask $script:folder $script:app.Process 'close' 'ping -n 60 127.0.0.1 >nul'
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder -TimeoutSec 2 -PollMs 200
            $watch.Stop()
            $r.Started | Should Be $true
            $r.Completed | Should Be $false
            $r.Reason | Should Be 'timeout'
            $watch.Elapsed.TotalSeconds | Should BeLessThan 15
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-TestTask $script:folder $name).State -ne 'Ready' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            [string](Get-TestTask $script:folder $name).State | Should Be 'Ready'
        }
    }

    Context 'against a faked Start-ScheduledTask' {
        BeforeEach {
            $script:folder = New-TestFolder
            $script:app = New-FakeApp -Process ('gwm-fake-' + [guid]::NewGuid().ToString('N'))
            # Registered again for every test, which also resets its call history.
            Mock Test-GwmInteractiveSession { $true }
            Mock Start-ScheduledTask { }
        }
        AfterEach { Remove-TestFolder $script:folder }

        It 'starts nothing when there is no task' {
            Mock Start-ScheduledTask { }
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder
            $r.Started | Should Be $false
            $r.Completed | Should Be $false
            $r.Reason | Should Be 'no-task'
            Assert-MockCalled Start-ScheduledTask -ParameterFilter { $TaskName -like ($script:app.Process + '*') } -Exactly -Times 0
        }
        It 'starts nothing when the task is disabled' {
            New-TestTask $script:folder $script:app.Process 'close' 'exit 0'
            Disable-ScheduledTask -TaskPath $script:folder -TaskName ($script:app.Process + '-close') | Out-Null
            Mock Start-ScheduledTask { }
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder
            $r.Started | Should Be $false
            $r.Reason | Should Be 'not-ready'
            Assert-MockCalled Start-ScheduledTask -ParameterFilter { $TaskName -like ($script:app.Process + '*') } -Exactly -Times 0
        }
        It 'reports launch-failed when the scheduler refuses to start the task' {
            New-TestTask $script:folder $script:app.Process 'close' 'exit 0'
            Mock Start-ScheduledTask { throw 'refused' }
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder
            $r.Started | Should Be $false
            $r.Completed | Should Be $false
            $r.Reason | Should Be 'launch-failed'
        }
        It 'does not count the result of an earlier run as completion' {
            New-TestTask $script:folder $script:app.Process 'close' 'exit 0'
            # A real run first, so the task is Ready and carries a successful LastRunTime/LastTaskResult.
            & schtasks.exe /Run /TN ($script:folder + $script:app.Process + '-close') | Out-Null
            $deadline = (Get-Date).AddSeconds(10)
            while ((Get-ScheduledTaskInfo -TaskPath $script:folder -TaskName ($script:app.Process + '-close')).LastTaskResult -eq 267011 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            Start-Sleep -Seconds 2
            # If the scheduler never starts it again, that old result must not be taken for this call.
            Mock Start-ScheduledTask { }
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder -TimeoutSec 2 -PollMs 200
            $r.Completed | Should Be $false
            $r.Reason | Should Be 'timeout'
        }
        It 'reports no-session and starts nothing when nobody is logged on' {
            Mock Test-GwmInteractiveSession { $false }
            Mock Start-ScheduledTask { }
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder
            $r.Started | Should Be $false
            $r.Completed | Should Be $false
            $r.Reason | Should Be 'no-session'
            Assert-MockCalled Start-ScheduledTask -ParameterFilter { $TaskName -like ($script:app.Process + '*') } -Exactly -Times 0
        }
    }

    Context 'against faked task information' {
        BeforeEach {
            $script:folder = New-TestFolder
            $script:app = New-FakeApp -Process ('gwm-fake-' + [guid]::NewGuid().ToString('N'))
            Mock Test-GwmInteractiveSession { $true }
            Mock Start-ScheduledTask { }
        }
        AfterEach { Remove-TestFolder $script:folder }

        It 'reports done with a non-zero result when the task ran and failed' {
            # conhost does not pass the exit code of its child on, so the failed run is simulated:
            # the first read is the state before the start, later reads show a finished run.
            New-TestTask $script:folder $script:app.Process 'open' 'exit 0'
            $script:reads = @{ n = 0 }
            Mock Get-ScheduledTaskInfo {
                $script:reads.n++
                if ($script:reads.n -le 1) { [pscustomobject]@{ LastRunTime = [datetime]'1999-11-30'; LastTaskResult = 267011 } }
                else { [pscustomobject]@{ LastRunTime = (Get-Date).AddSeconds(5); LastTaskResult = 7 } }
            }
            $r = Invoke-GwmTask -App $script:app -Action open -TaskFolder $script:folder -TimeoutSec 5 -PollMs 100
            $r.Started | Should Be $true
            $r.Completed | Should Be $true
            $r.Result | Should Be 7
            $r.Reason | Should Be 'done'
        }
        It 'does not count an earlier run from the same second as the start' {
            # LastRunTime has a resolution of one second, so a run just before the start can share its second.
            New-TestTask $script:folder $script:app.Process 'close' 'exit 0'
            # The clock is fixed so the earlier run really shares the second of the start.
            $script:fixedNow = [datetime]'2030-01-01T10:00:00.700'
            $script:earlierRun = [datetime]'2030-01-01T10:00:00'
            Mock Get-Date { $script:fixedNow }
            Mock Get-ScheduledTaskInfo { [pscustomobject]@{ LastRunTime = $script:earlierRun; LastTaskResult = 0 } }
            Mock Start-ScheduledTask { }
            $r = Invoke-GwmTask -App $script:app -Action close -TaskFolder $script:folder -TimeoutSec 2 -PollMs 200
            $r.Completed | Should Be $false
            $r.Reason | Should Be 'timeout'
        }
    }

    Context 'the default folder' {
        It 'looks in the production folder by default' {
            $app = New-FakeApp -Process ('gwm-fake-' + [guid]::NewGuid().ToString('N'))
            Mock Test-GwmInteractiveSession { $true }
            Mock Get-ScheduledTask { $null }
            Mock Start-ScheduledTask { }
            $r = Invoke-GwmTask -App $app -Action close
            $r.Reason | Should Be 'no-task'
            Assert-MockCalled Get-ScheduledTask -ParameterFilter { $TaskPath -eq '\wau-graceful-mods\' } -Times 1
            Assert-MockCalled Start-ScheduledTask -Exactly -Times 0
        }
    }
}

Describe 'the throwaway folders of this file' {
    It 'are all gone, so no scheduled task is left behind' {
        $script:madeFolders.Count | Should BeGreaterThan 10
        $left = @($script:madeFolders | Where-Object { Test-TestFolderExists $_ })
        ($left -join ',') | Should Be ''
    }
}
