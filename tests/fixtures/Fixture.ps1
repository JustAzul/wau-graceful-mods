# Test fixtures: tiny executables with a controlled reaction to WM_CLOSE.
#
# Every fixture is compiled with Add-Type into the Windows temp folder under a unique
# name (gwm-fixture-<guid>.exe), so the process name is unique to the test that owns it.
# Windows are 1x1, off screen, out of the taskbar and never take focus. Each fixture ends
# itself after about 60 seconds as a safety net.
#
# Two kinds, chosen with New-GwmFixture -Kind:
#
# raw (default): the window is created with plain user32 calls. There are no framework
#   helper windows, so the window procedure is the only thing that reacts to a close.
#   Modes: exit    exits when closed; the handler appends "closing" to the marker file
#          ignore  cancels every close; appends "close-attempt" per attempt
#          hidden  the window is never shown; exits when closed
#          tray    first close hides the window ("close-1-hide"), the second exits
#                  ("close-2-exit")
#          decoys  a hidden main window that ignores closes, plus hidden decoy windows that
#                  must NOT be targeted: a window of another class (class GwmFixtureHelper),
#                  a matching-class window with an empty title and a matching-class owned
#                  window. Closing any decoy appends "decoy-closed:<name>" and ends the
#                  process, like a framework helper window would. Main class: GwmFixtureWindow.
#
# winforms: a real System.Windows.Forms process with the framework's own hidden helper
#   windows (parking window WindowsForms10.Window.0.*, .NET-BroadcastEventWindow, IME).
#   Closing the parking window ends the process without running FormClosing (the fixture
#   exits when the helper form the parking window owns is destroyed), which is the failure
#   the targeting rule exists to avoid.
#   Modes: exit, ignore, tray (visible form, FormClosing handler writes the marker as in raw)
#          hidden-exit, hidden-ignore (the form is shown once and then hidden, the shape of a
#          main window living in the tray; a form that was never shown ignores WM_CLOSE
#          altogether, so it is not a usable stand-in). Main class: WindowsForms10.Window.8.*
#
# Arguments: <mode> <marker file> <ready file>. The ready file appears once the windows
# exist, so a test never races the start-up.

$script:GwmFixtureTmp = [System.IO.Path]::GetFullPath($env:TEMP)
$script:GwmFixtures = @()

$script:GwmFixtureSource = @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

namespace __NS__
{
    public static class Program
    {
        private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WNDCLASS
        {
            public uint style;
            public IntPtr lpfnWndProc;
            public int cbClsExtra;
            public int cbWndExtra;
            public IntPtr hInstance;
            public IntPtr hIcon;
            public IntPtr hCursor;
            public IntPtr hbrBackground;
            public string lpszMenuName;
            public string lpszClassName;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MSG
        {
            public IntPtr hwnd;
            public uint message;
            public IntPtr wParam;
            public IntPtr lParam;
            public uint time;
            public int x;
            public int y;
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern ushort RegisterClass(ref WNDCLASS wc);

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateWindowEx(uint exStyle, string className, string title, uint style,
            int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);

        [DllImport("user32.dll")]
        private static extern bool ShowWindow(IntPtr hWnd, int cmd);

        [DllImport("user32.dll")]
        private static extern bool DestroyWindow(IntPtr hWnd);

        [DllImport("user32.dll")]
        private static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern void PostQuitMessage(int exitCode);

        [DllImport("user32.dll")]
        private static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);

        [DllImport("user32.dll")]
        private static extern bool TranslateMessage(ref MSG msg);

        [DllImport("user32.dll")]
        private static extern IntPtr DispatchMessage(ref MSG msg);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr GetModuleHandle(string name);

        private const uint WM_DESTROY = 0x0002;
        private const uint WM_CLOSE = 0x0010;

        private static WndProcDelegate keepAlive;
        private static System.Threading.Timer safety;
        private static string behavior;
        private static string marker;
        private static int closes;
        private static Dictionary<long, string> decoys = new Dictionary<long, string>();

        private static void Note(string text)
        {
            try { File.AppendAllText(marker, text + "\r\n"); }
            catch (Exception) { }
        }

        private static IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
        {
            if (msg == WM_CLOSE)
            {
                string decoy;
                if (decoys.TryGetValue(hWnd.ToInt64(), out decoy))
                {
                    Note("decoy-closed:" + decoy);
                    DestroyWindow(hWnd);
                    return IntPtr.Zero;
                }
                closes++;
                if (behavior == "ignore")
                {
                    Note("close-attempt");
                    return IntPtr.Zero;
                }
                if (behavior == "tray" && closes == 1)
                {
                    Note("close-1-hide");
                    ShowWindow(hWnd, 0); // SW_HIDE
                    return IntPtr.Zero;
                }
                Note(behavior == "tray" ? "close-2-exit" : "closing");
                DestroyWindow(hWnd);
                return IntPtr.Zero;
            }
            if (msg == WM_DESTROY)
            {
                PostQuitMessage(0);
                return IntPtr.Zero;
            }
            return DefWindowProc(hWnd, msg, wParam, lParam);
        }

        private static void Register(string className, IntPtr instance)
        {
            WNDCLASS wc = new WNDCLASS();
            wc.lpfnWndProc = Marshal.GetFunctionPointerForDelegate(keepAlive);
            wc.hInstance = instance;
            wc.lpszClassName = className;
            RegisterClass(ref wc);
        }

        // WS_POPUP; WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE: no taskbar button, never activated.
        private static IntPtr Make(string className, string title, IntPtr owner, IntPtr instance)
        {
            return CreateWindowEx(0x08000080, className, title, 0x80000000,
                -32000, -32000, 1, 1, owner, IntPtr.Zero, instance, IntPtr.Zero);
        }

        public static void Main(string[] args)
        {
            string mode = args[0];
            marker = args[1];
            string ready = args[2];

            bool visible = !(mode == "hidden" || mode == "decoys");
            behavior = mode == "hidden" ? "exit" : (mode == "decoys" ? "ignore" : mode);

            safety = new System.Threading.Timer(
                delegate(object state) { Environment.Exit(0); },
                null, 60000, System.Threading.Timeout.Infinite);

            keepAlive = new WndProcDelegate(WndProc);
            IntPtr instance = GetModuleHandle(null);
            Register("GwmFixtureWindow", instance);
            Register("GwmFixtureHelper", instance);

            IntPtr main = Make("GwmFixtureWindow", "gwm-fixture", IntPtr.Zero, instance);
            if (main == IntPtr.Zero)
            {
                return;
            }
            if (visible)
            {
                ShowWindow(main, 4); // SW_SHOWNOACTIVATE
            }

            if (mode == "decoys")
            {
                decoys[Make("GwmFixtureHelper", "helper", IntPtr.Zero, instance).ToInt64()] = "other-class";
                decoys[Make("GwmFixtureWindow", "", IntPtr.Zero, instance).ToInt64()] = "no-title";
                decoys[Make("GwmFixtureWindow", "owned", main, instance).ToInt64()] = "owned";
            }
            File.WriteAllText(ready, "ready");

            MSG message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref message);
                DispatchMessage(ref message);
            }
        }
    }
}
'@

$script:GwmWinFormsSource = @'
using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace __NS__
{
    public class QuietForm : Form
    {
        protected override bool ShowWithoutActivation { get { return true; } }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= 0x08000000; // WS_EX_NOACTIVATE
                cp.ExStyle |= 0x00000080; // WS_EX_TOOLWINDOW
                return cp;
            }
        }
    }

    public static class Program
    {
        static System.Threading.Timer safety;
        static string marker;

        static void Note(string text)
        {
            try { File.AppendAllText(marker, text + "\r\n"); }
            catch (Exception) { }
        }

        [STAThread]
        public static void Main(string[] args)
        {
            string mode = args[0];
            marker = args[1];
            string ready = args[2];
            bool hiddenMain = mode.StartsWith("hidden-");
            string behavior = hiddenMain ? mode.Substring(7) : mode;

            safety = new System.Threading.Timer(
                delegate(object state) { Environment.Exit(0); },
                null, 60000, System.Threading.Timeout.Infinite);

            QuietForm form = new QuietForm();
            form.FormBorderStyle = FormBorderStyle.None;
            form.StartPosition = FormStartPosition.Manual;
            form.Location = new Point(-32000, -32000);
            form.Size = new Size(1, 1);
            // Not ShowInTaskbar = false: WinForms then makes the form owned by its parking
            // window, unlike a real main window. WS_EX_TOOLWINDOW already keeps it off the taskbar.
            form.Text = "gwm-fixture";

            // A second form that is never shown and has ShowInTaskbar = false is owned by the
            // parking window, so the process owns the hidden framework helper window
            // (WindowsForms10.Window.0.*) every real WinForms app has. It is owned itself, so the
            // targeting rule must skip it too.
            Form helper = new Form();
            helper.ShowInTaskbar = false;
            IntPtr helperHandle = helper.Handle;
            // Closing the parking window destroys the windows it owns. Treat that as the end of
            // the app, with no FormClosing, like an app whose main window hangs off it.
            helper.HandleDestroyed += delegate(object sender, EventArgs e)
            {
                Application.ExitThread();
            };

            int closes = 0;
            form.FormClosing += delegate(object sender, FormClosingEventArgs e)
            {
                closes++;
                if (behavior == "ignore")
                {
                    Note("close-attempt");
                    e.Cancel = true;
                    return;
                }
                if (behavior == "tray" && closes == 1)
                {
                    Note("close-1-hide");
                    e.Cancel = true;
                    form.Hide();
                    return;
                }
                Note(behavior == "tray" ? "close-2-exit" : "closing");
            };
            form.FormClosed += delegate(object sender, FormClosedEventArgs e)
            {
                Application.ExitThread();
            };

            form.Shown += delegate(object sender, EventArgs e)
            {
                if (hiddenMain)
                {
                    form.Hide(); // shown once, then living hidden like a tray application
                }
                File.WriteAllText(ready, "ready");
            };

            Application.Run(form);
        }
    }
}
'@

function New-GwmFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [ValidateSet('raw', 'winforms')][string]$Kind = 'raw',
        # Override only to build a name that starts with another fixture's name.
        [string]$Name
    )

    $modes = @{
        raw      = @('exit', 'ignore', 'hidden', 'tray', 'decoys')
        winforms = @('exit', 'ignore', 'tray', 'hidden-exit', 'hidden-ignore')
    }
    if ($modes[$Kind] -notcontains $Mode) {
        throw "Unknown mode '$Mode' for a $Kind fixture"
    }
    if (-not $Name) {
        $Name = 'gwm-fixture-' + [guid]::NewGuid().ToString('N')
    }
    $exe = Join-Path $script:GwmFixtureTmp ($Name + '.exe')
    $fixture = [pscustomobject]@{
        Mode    = $Mode
        Kind    = $Kind
        Name    = $Name
        Path    = $exe
        Marker  = Join-Path $script:GwmFixtureTmp ($Name + '.marker')
        Ready   = Join-Path $script:GwmFixtureTmp ($Name + '.ready')
        Process = $null
    }
    # Track it before compiling so a failed compile still gets cleaned up.
    $script:GwmFixtures += $fixture

    $namespace = 'GwmFx' + [guid]::NewGuid().ToString('N')
    if ($Kind -eq 'winforms') {
        $source = $script:GwmWinFormsSource.Replace('__NS__', $namespace)
        Add-Type -TypeDefinition $source -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' `
            -OutputAssembly $exe -OutputType WindowsApplication
    }
    else {
        $source = $script:GwmFixtureSource.Replace('__NS__', $namespace)
        Add-Type -TypeDefinition $source -OutputAssembly $exe -OutputType WindowsApplication
    }
    $fixture
}

function Start-GwmFixture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Fixture,
        [int]$ReadyTimeoutSec = 20
    )

    $arguments = @($Fixture.Mode, ('"{0}"' -f $Fixture.Marker), ('"{0}"' -f $Fixture.Ready))
    $process = Start-Process -FilePath $Fixture.Path -ArgumentList $arguments -PassThru
    $Fixture.Process = $process

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $Fixture.Ready)) {
        if ($process.HasExited) { throw "Fixture $($Fixture.Name) exited before it was ready" }
        if ($sw.Elapsed.TotalSeconds -gt $ReadyTimeoutSec) { throw "Fixture $($Fixture.Name) was not ready in time" }
        Start-Sleep -Milliseconds 100
    }
    $Fixture
}

function Test-GwmFixtureAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture)

    if ($null -eq $Fixture.Process) { return $false }
    $Fixture.Process.Refresh()
    [bool](-not $Fixture.Process.HasExited)
}

function Get-GwmFixtureMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fixture)

    if (-not (Test-Path -LiteralPath $Fixture.Marker)) { return @() }
    @(Get-Content -LiteralPath $Fixture.Marker | Where-Object { $_ })
}

# Stops only the PIDs this session started (and only while the PID still carries the
# fixture's own name), then deletes every file the fixtures created.
function Remove-GwmFixtures {
    [CmdletBinding()]
    param()

    foreach ($fixture in $script:GwmFixtures) {
        if ($null -ne $fixture.Process) {
            $id = $fixture.Process.Id
            $live = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($null -ne $live -and $live.ProcessName -eq $fixture.Name) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
                [void]$live.WaitForExit(5000)
            }
        }
        foreach ($file in $fixture.Path, $fixture.Marker, $fixture.Ready) {
            for ($i = 0; $i -lt 15 -and (Test-Path -LiteralPath $file); $i++) {
                Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $file) { Start-Sleep -Milliseconds 200 }
            }
        }
    }
    $script:GwmFixtures = @()
}
