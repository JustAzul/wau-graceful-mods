# User-session scheduled tasks that close and reopen machine-scope apps.
#
# WAU runs as SYSTEM in session 0 and cannot touch a window on the desktop. Each
# close-reopen machine app therefore gets two tasks that run as the desktop user
# (interactive token, limited run level, no trigger): <Process>-close and
# <Process>-open. Invoke-GwmTask starts one and waits for it to finish.

function Format-GwmTaskFolder {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)][string]$TaskFolder
    )

    '\' + $TaskFolder.Trim('\') + '\'
}

function Get-GwmTaskName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)][ValidateSet('close', 'open')][string]$Action
    )

    '{0}-{1}' -f $App.Process, $Action
}

function New-GwmTaskSpec {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)][ValidateSet('close', 'open')][string]$Action,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$TasksDir,
        [Parameter(Mandatory = $true)][string]$TaskFolder,
        [string]$ExePath,
        # The wrapper decides whether the app exited; the caller of Invoke-GwmTask waits longer than this.
        [int]$TimeoutSec = 60
    )

    # Values end up inside a quoted command line; a quote would let one argument leak into the next.
    $quoted = @($App.Process, $TasksDir)
    if ($Action -eq 'open') {
        if ([string]::IsNullOrWhiteSpace($ExePath)) {
            throw 'New-GwmTaskSpec: ExePath is required for the open task'
        }
        $quoted += $ExePath
    }
    foreach ($value in $quoted) {
        if ([string]$value -match '"') {
            throw "New-GwmTaskSpec: a double quote is not allowed in '$value' (it would break the quoted command line)"
        }
    }

    $verb = if ($Action -eq 'close') { 'Close' } else { 'Open' }
    $script = Join-Path $TasksDir ('Invoke-{0}Task.ps1' -f $verb)
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ProcessName "{1}"' -f $script, $App.Process
    if ($Action -eq 'close') {
        $arguments += ' -TimeoutSec {0}' -f $TimeoutSec
        # The wrapper waits up to TimeoutSec; leave room for it to report before the scheduler gives up.
        $limit = [timespan]::FromSeconds($TimeoutSec + 60)
    }
    else {
        $arguments += ' -ExePath "{0}"' -f $ExePath
        $limit = [timespan]::FromSeconds(60)
    }

    [pscustomobject]@{
        TaskPath           = Format-GwmTaskFolder -TaskFolder $TaskFolder
        TaskName           = Get-GwmTaskName -App $App -Action $Action
        Execute            = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Arguments          = $arguments
        UserSid            = $UserSid
        LogonType          = 'Interactive'
        RunLevel           = 'Limited'
        MultipleInstances  = 'IgnoreNew'
        ExecutionTimeLimit = $limit
    }
}

function Test-GwmManagedApp {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]$App
    )

    [bool]($App.Scope -eq 'machine' -and $App.Policy -eq 'close-reopen')
}

function Register-GwmTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable[]]$Apps,
        [Parameter(Mandatory = $true)][string]$UserSid,
        [Parameter(Mandatory = $true)][string]$TasksDir,
        [Parameter(Mandatory = $true)][string]$TaskFolder,
        $UserContext
    )

    foreach ($app in $Apps) {
        if (-not (Test-GwmManagedApp -App $app)) {
            continue
        }

        $specs = @()
        $specs += New-GwmTaskSpec -App $app -Action close -UserSid $UserSid -TasksDir $TasksDir -TaskFolder $TaskFolder

        $exe = Resolve-GwmExe -App $app -UserContext $UserContext
        if ($exe) {
            $specs += New-GwmTaskSpec -App $app -Action open -UserSid $UserSid -TasksDir $TasksDir -TaskFolder $TaskFolder -ExePath $exe
        }
        else {
            Write-GwmLog "No executable found for $($app.Process); the open task is not registered"
        }

        foreach ($spec in $specs) {
            $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Arguments
            $principal = New-ScheduledTaskPrincipal -UserId $spec.UserSid -LogonType $spec.LogonType -RunLevel $spec.RunLevel
            # Battery switches: the defaults would refuse to start the task on a laptop that is unplugged.
            $settings = New-ScheduledTaskSettingsSet -MultipleInstances $spec.MultipleInstances `
                -ExecutionTimeLimit $spec.ExecutionTimeLimit -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
            Register-ScheduledTask -TaskPath $spec.TaskPath -TaskName $spec.TaskName `
                -Action $action -Principal $principal -Settings $settings -Force | Out-Null
            Write-GwmLog "Registered task $($spec.TaskPath)$($spec.TaskName)"
            $spec
        }
    }
}

function Unregister-GwmTasks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable[]]$Apps,
        [Parameter(Mandatory = $true)][string]$TaskFolder
    )

    $path = Format-GwmTaskFolder -TaskFolder $TaskFolder
    foreach ($app in $Apps) {
        if (-not (Test-GwmManagedApp -App $app)) {
            continue
        }
        foreach ($action in 'close', 'open') {
            $name = Get-GwmTaskName -App $app -Action $action
            try {
                Unregister-ScheduledTask -TaskPath $path -TaskName $name -Confirm:$false -ErrorAction Stop
                Write-GwmLog "Removed task $path$name"
            }
            catch {
                # A task that is not there is the normal case; anything else is a real failure.
                if (Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue) {
                    throw
                }
            }
        }
    }
}

function Test-GwmInteractiveSession {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    # A desktop exists once explorer.exe runs; before the logon finishes there is no one to ask.
    [bool](@(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_ }).Count -gt 0)
}

function New-GwmTaskResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$Started,
        [Parameter(Mandatory = $true)][bool]$Completed,
        [Parameter(Mandatory = $true)][int]$Result,
        [Parameter(Mandatory = $true)][string]$Reason
    )

    [pscustomobject]@{
        Started   = $Started
        Completed = $Completed
        Result    = $Result
        Reason    = $Reason
    }
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

    $name = Get-GwmTaskName -App $App -Action $Action
    $path = Format-GwmTaskFolder -TaskFolder $TaskFolder

    if (-not (Test-GwmInteractiveSession)) {
        Write-GwmLog "No interactive session; task $path$name not started"
        return New-GwmTaskResult -Started $false -Completed $false -Result -1 -Reason 'no-session'
    }

    $task = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
    if (-not $task) {
        Write-GwmLog "Task $path$name does not exist"
        return New-GwmTaskResult -Started $false -Completed $false -Result -1 -Reason 'no-task'
    }
    if ([string]$task.State -ne 'Ready') {
        Write-GwmLog "Task $path$name is $($task.State), not Ready; not started"
        return New-GwmTaskResult -Started $false -Completed $false -Result -1 -Reason 'not-ready'
    }

    # LastRunTime has a resolution of one second. Remember the value from before the start: a
    # finished run is one that moved it forward, so the result of an earlier run is never taken
    # for this one, even when that run fell into the same second as the start.
    $previousRun = (Get-ScheduledTaskInfo -TaskPath $path -TaskName $name).LastRunTime
    $started = Get-Date
    $startedWhole = $started.AddTicks(-($started.Ticks % [timespan]::TicksPerSecond))

    try {
        Start-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop
    }
    catch {
        Write-GwmLog "Task $path$name could not be started: $($_.Exception.Message)"
        return New-GwmTaskResult -Started $false -Completed $false -Result -1 -Reason 'launch-failed'
    }

    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        # The scheduler is read in three separate calls, so the order matters: first a new
        # LastRunTime (a run began), then state Ready (it is over), then the final result.
        $info = Get-ScheduledTaskInfo -TaskPath $path -TaskName $name
        if ($info.LastRunTime -gt $previousRun -and $info.LastRunTime -ge $startedWhole) {
            $current = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
            if ($current -and [string]$current.State -eq 'Ready') {
                $final = Get-ScheduledTaskInfo -TaskPath $path -TaskName $name
                # 267009 is SCHED_S_TASK_RUNNING: the run reported by the state read was not over yet.
                if ([int]$final.LastTaskResult -ne 267009) {
                    return New-GwmTaskResult -Started $true -Completed $true -Result ([int]$final.LastTaskResult) -Reason 'done'
                }
            }
        }
        if ($watch.Elapsed.TotalSeconds -ge $TimeoutSec) {
            break
        }
        Start-Sleep -Milliseconds $PollMs
    }

    Write-GwmLog "Task $path$name did not finish within $TimeoutSec s; stopping it"
    Stop-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction SilentlyContinue
    New-GwmTaskResult -Started $true -Completed $false -Result -1 -Reason 'timeout'
}
