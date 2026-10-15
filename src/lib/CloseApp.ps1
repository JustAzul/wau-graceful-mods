# Graceful close of an application (WM_CLOSE only, never a kill).

function Initialize-GwmWindowApi {
    [CmdletBinding()]
    param()

    # Guarded: re-running in one session must not fail on an already defined type.
    if ('GwmNative.CloseAppWindows' -as [type]) {
        return
    }
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace GwmNative
{
    public static class CloseAppWindows
    {
        private delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool EnumWindows(EnumProc callback, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [DllImport("user32.dll")]
        private static extern bool IsWindowVisible(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetWindowTextLength(IntPtr hWnd);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder text, int maxCount);

        [DllImport("user32.dll")]
        private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        private const uint WM_CLOSE = 0x0010;
        private const uint GW_OWNER = 4;

        // Every top-level window owned by the process, visible or hidden.
        public static IntPtr[] GetWindows(uint processId)
        {
            List<IntPtr> found = new List<IntPtr>();
            EnumWindows(delegate(IntPtr hWnd, IntPtr lParam)
            {
                uint owner;
                GetWindowThreadProcessId(hWnd, out owner);
                if (owner == processId)
                {
                    found.Add(hWnd);
                }
                return true;
            }, IntPtr.Zero);
            return found.ToArray();
        }

        public static bool IsVisible(IntPtr hWnd)
        {
            return IsWindowVisible(hWnd);
        }

        public static bool IsOwned(IntPtr hWnd)
        {
            return GetWindow(hWnd, GW_OWNER) != IntPtr.Zero;
        }

        public static bool HasTitle(IntPtr hWnd)
        {
            return GetWindowTextLength(hWnd) > 0;
        }

        public static string GetClassName(IntPtr hWnd)
        {
            System.Text.StringBuilder text = new System.Text.StringBuilder(256);
            GetClassName(hWnd, text, text.Capacity);
            return text.ToString();
        }

        public static bool PostClose(IntPtr hWnd)
        {
            return PostMessage(hWnd, WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
        }
    }
}
'@
}

function Get-GwmCloseWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][uint32]$ProcessId,
        [string[]]$HiddenWindowClass
    )

    # Targets: every visible top-level window of the process, plus, only when classes are
    # given, hidden windows that are unowned, titled and of a matching class. Any other
    # hidden window is a framework helper (WinForms parking window, Qt message windows,
    # IME ...) whose WM_CLOSE can end the process without running its close handler.
    $patterns = @($HiddenWindowClass | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($window in @([GwmNative.CloseAppWindows]::GetWindows($ProcessId))) {
        if ([GwmNative.CloseAppWindows]::IsVisible($window)) {
            $window
            continue
        }
        if ($patterns.Count -eq 0) { continue }
        if ([GwmNative.CloseAppWindows]::IsOwned($window)) { continue }
        if (-not [GwmNative.CloseAppWindows]::HasTitle($window)) { continue }
        $class = [GwmNative.CloseAppWindows]::GetClassName($window)
        foreach ($pattern in $patterns) {
            if ($class -like $pattern) {
                $window
                break
            }
        }
    }
}

function Get-GwmWindowKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Window
    )

    # A window counts as "asked before" per visibility: one that was visible when asked and
    # is hidden now (close to tray) is a new target again, one that stays visible is not.
    $state = 'hidden'
    if ([GwmNative.CloseAppWindows]::IsVisible($Window)) { $state = 'visible' }
    '{0}:{1}' -f [int64]$Window, $state
}

function Get-GwmSessionProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName
    )

    # Exact, case-insensitive name match inside the caller's session. Get-Process -Name is
    # not used: it treats the name as a wildcard pattern.
    $sessionId = [System.Diagnostics.Process]::GetCurrentProcess().SessionId
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        if ($process.ProcessName -eq $ProcessName -and $process.SessionId -eq $sessionId) {
            $process
        }
    }
}

function Test-GwmProcessGone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Process
    )

    try {
        $Process.Refresh()
        return [bool]$Process.HasExited
    }
    catch {
        # Cannot tell (for example access denied): treat the process as still running.
        return $false
    }
}

function Close-App {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName,
        [string[]]$HiddenWindowClass,
        [ValidateRange(0, 86400)][int]$TimeoutSec = 30,
        [ValidateRange(10, 60000)][int]$PollMs = 250
    )

    $targets = @(Get-GwmSessionProcess -ProcessName $ProcessName)
    if ($targets.Count -eq 0) {
        return [pscustomobject]@{
            ProcessName = $ProcessName
            Found       = $false
            Exited      = $true
            Reason      = 'not-running'
        }
    }

    Initialize-GwmWindowApi
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $timeoutMs = $TimeoutSec * 1000

    # Per process: the windows already sent WM_CLOSE, and whether the second round (close to
    # tray: the app hid its window, or opened a new one) has been used.
    $state = @{}
    foreach ($target in $targets) {
        $posted = @{}
        $windows = @(Get-GwmCloseWindow -ProcessId ([uint32]$target.Id) -HiddenWindowClass $HiddenWindowClass)
        foreach ($window in $windows) {
            $posted[(Get-GwmWindowKey -Window $window)] = $true
            [void][GwmNative.CloseAppWindows]::PostClose($window)
        }
        $state[[int]$target.Id] = @{ Posted = $posted; Retried = $false }
        Write-GwmLog "Close-App: asked $ProcessName (pid $($target.Id)) to close, $($windows.Count) window(s)"
    }

    while ($true) {
        $alive = @($targets | Where-Object { -not (Test-GwmProcessGone -Process $_) })
        if ($alive.Count -eq 0) {
            return [pscustomobject]@{
                ProcessName = $ProcessName
                Found       = $true
                Exited      = $true
                Reason      = 'exited'
            }
        }

        # Close-to-tray: recompute the targets and ask once more through the windows that
        # were not asked before (a window that was visible and is now hidden qualifies only
        # through HiddenWindowClass). One extra round per process.
        foreach ($target in $alive) {
            $entry = $state[[int]$target.Id]
            if ($entry.Retried) { continue }
            $fresh = @(Get-GwmCloseWindow -ProcessId ([uint32]$target.Id) -HiddenWindowClass $HiddenWindowClass |
                Where-Object { -not $entry.Posted.ContainsKey((Get-GwmWindowKey -Window $_)) })
            if ($fresh.Count -gt 0) {
                $entry.Retried = $true
                foreach ($window in $fresh) {
                    $entry.Posted[(Get-GwmWindowKey -Window $window)] = $true
                    [void][GwmNative.CloseAppWindows]::PostClose($window)
                }
                Write-GwmLog "Close-App: $ProcessName (pid $($target.Id)) shows new targets, asked again"
            }
        }

        $remaining = $timeoutMs - $stopwatch.ElapsedMilliseconds
        if ($remaining -le 0) {
            break
        }
        Start-Sleep -Milliseconds ([int][Math]::Min([long]$PollMs, $remaining))
    }

    Write-GwmLog "Close-App: $ProcessName still running after $TimeoutSec s"
    [pscustomobject]@{
        ProcessName = $ProcessName
        Found       = $true
        Exited      = $false
        Reason      = 'timeout'
    }
}
