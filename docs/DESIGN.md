# Design

Names, shapes and rules the code follows: conventions, layout, the app manifest and the
behaviour of each component.

## 1. Conventions

- Target: Windows PowerShell 5.1 only. No `??`, no ternary, no `&&` / `||` pipeline
  chains, no `ForEach-Object -Parallel`, nothing that needs PowerShell 7.
- Source files are ASCII only (5.1 reads BOM-less UTF-8 as ANSI). Text and comments are
  in English.
- The repository is public. Never write a user name, e-mail address, machine name, IP,
  or absolute user path into a file. Resolve them at runtime (`$env:...`,
  `[Environment]::GetFolderPath`). Test data uses obviously fake values (`fake-user`).
- Libraries are dot-sourced `.ps1` files that only define functions. No side effects at
  load time. Functions are advanced functions (`[CmdletBinding()]`), approved verbs,
  with the parameter names given here.
- Output discipline: a function emits exactly the value in its contract on the success
  pipeline and nothing else. Logging goes through `Write-GwmLog`. Mod entry functions
  return exactly one `[bool]` (WAU tests `(& $mod) -eq $false`; an array would break it).
- Every function must be safe under `Set-StrictMode -Version 2`. Remember that
  `@($null).Count` is 1: filter nulls before counting.
- Do not use `$env:TEMP` / `$env:TMP` raw for file operations. They can be in 8.3 form
  (`USERNA~1`) and `Remove-Item`, `Set-Location` and others reject that segment. Use
  `[System.IO.Path]::GetFullPath($env:TEMP)`.

## 2. Tests

- Pester **3.4.0** syntax: `Describe` / `Context` / `It`, `Should Be`, `Mock`,
  `Assert-MockCalled`. One test file per source file: `tests/<Name>.Tests.ps1`.
- Pester 3.4 gotchas already met: `Should Contain` reads a **file**; test list membership
  with `($list -contains 'x') | Should Be $true`. Check before relying on `BeforeAll` /
  `AfterAll`; use `AfterEach` or `try` / `finally` when unsure.
- Each test file starts with
  `$here = Split-Path -Parent $MyInvocation.MyCommand.Path`,
  `$root = Split-Path -Parent $here` and dot-sources the files it needs from
  `$root\src\lib\...`. Collaborators that are not under test are stubbed:
  define a function with the documented signature in the test and `Mock` it.
- Run: `scripts/run-tests.sh [tests/<Name>.Tests.ps1 ...]` from WSL. It copies the repo to a
  private Windows temp directory and runs Pester 3.4 on PowerShell 5.1. The exit code is
  the number of failed tests (2 = Pester did not run).
- The suite may run in parallel with other runs on the same machine. A test may only touch
  processes, scheduled tasks and files that it created itself, under a unique name (add a
  GUID). Never match processes by a name real software uses (`powershell`, `notepad`,
  `explorer`, `qbittorrent`, ...). Never use `Stop-Process -Name`; kill only a PID you
  started. Clean up in `AfterEach` / `finally`.
- More Pester 3.4 behaviour met in this project: `Should` emits `$true` on success, so a helper
  function that calls `Should` and is piped into `Should Be $false` sees `True True False`
  (pipe the helper's `Should` calls to `Out-Null`). A `Mock` re-declared in `BeforeEach` keeps
  its call history across tests, so `Assert-MockCalled -Exactly` counts accumulate; count
  calls through a log the test keeps instead. `Assert-MockCalled -Times 0` without `-Exactly` always
  passes.
- `GWM_STRICT=1 scripts/run-tests.sh` runs the suite under `Set-StrictMode -Version 2`;
  the libraries and installer scripts must pass it, and so must the test code.
- TDD: one failing test, then the minimal code, repeat. See the failure first and check
  it is the assertion that fails, not the harness. Refactor only on green.

## 3. Layout

Repository:

```
config/apps.psd1                  manifest
src/lib/*.ps1                     libraries, copied to <gwm>\lib
src/tasks/*.ps1                   scheduled-task wrappers, copied to <gwm>\tasks
src/mods/_WAU-mods.ps1            global mod, copied to <WauDir>\mods
install/*.ps1                     installer side only, never copied to the runtime
tests/*.Tests.ps1, tests/fixtures/
scripts/, docs/                   tooling and documentation
```

Runtime on the machine (written by the installer):

```
<WauDir>\mods\_WAU-mods.ps1
<WauDir>\mods\<AppId>-preinstall.ps1 | -installed.ps1 | -notinstalled.ps1   thin generated mods
<WauDir>\mods\gwm\apps.psd1
<WauDir>\mods\gwm\context.json    { UserSid, ProfilePath } of the desktop user
<WauDir>\mods\gwm\lib\*.ps1       Load.ps1 dot-sources the rest
<WauDir>\mods\gwm\tasks\Invoke-CloseTask.ps1, Invoke-OpenTask.ps1
%ProgramData%\wau-graceful-mods\state\    reopen markers (override: $env:GWM_STATE_DIR)
%ProgramData%\wau-graceful-mods\backups\
```

A thin mod is generated text, for example `qBittorrent.qBittorrent-preinstall.ps1`:

```powershell
. "$PSScriptRoot\gwm\lib\Load.ps1"
Invoke-GwmPreInstall -AppId 'qBittorrent.qBittorrent' -InstalledVersion $app.Version -AvailableVersion $app.AvailableVersion
```

`$app` is WAU's per-app variable, visible through dynamic scope. The `-installed` and
`-notinstalled` mods call `Invoke-GwmPostInstall -AppId '<id>' -Succeeded $true` and
`-Succeeded $false`.

## 4. Manifest

`config/apps.psd1` keys: `SchemaVersion`, `TaskFolder`, `SelfId`, `Apps`, `DefaultApps`.
Each app hashtable: `Id`, `Process`, `Scope` (`machine` | `user`), `Policy`
(`close-reopen` | `skip-if-open`), optional `Autostart` [bool], `Exe` [string[]] (required
for `close-reopen`), optional `BackupOnMajorUpgrade` [string path template], optional
`HiddenWindowClass` [string[]] (non-blank `-like` class name patterns of the app's own main
window when that window lives hidden in the tray).

Functions in `src/lib/Manifest.ps1`:

| Function | Returns |
|---|---|
| `Import-GwmManifest -Path` | validated hashtable; throws on bad data |
| `Get-GwmApp -Manifest -Id` | the app hashtable or `$null` (case-insensitive) |
| `Get-GwmWhitelist -Manifest` | sorted unique `[string[]]` of every id incl. `SelfId` |
| `Expand-GwmPath -Path [-UserContext]` | `%VAR%` expanded; with a context, `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%` map onto `ProfilePath` |
| `Resolve-GwmExe -App [-UserContext]` | first existing expanded `Exe` candidate or `$null` |
| `Save-GwmUserContext -Path -UserSid -ProfilePath` | writes the JSON file |
| `Get-GwmUserContext -Path` | `[pscustomobject]` with `UserSid`, `ProfilePath`, or `$null` |

Also: `Write-GwmLog -Message` (`Log.ps1`) and `Test-GwmProcessRunning -ProcessName` ->
`[bool]`, any session (`Process.ps1`).

## 5. Close-App (`src/lib/CloseApp.ps1`)

```
Close-App -ProcessName <string> [-HiddenWindowClass <string[]>] [-TimeoutSec <int> = 30] [-PollMs <int> = 250]
```

Returns one `[pscustomobject]`: `ProcessName`, `Found` [bool], `Exited` [bool],
`Reason` [string]: `not-running` (Found false, Exited true) | `exited` | `timeout`.

Behaviour:

- Looks only at processes of the **caller's session**, exact name match (case-insensitive),
  not a prefix.
- Window targeting (see the note below). For each target
  process post `WM_CLOSE` (0x0010) only to:
  1. every **visible** top-level window it owns, and
  2. when `-HiddenWindowClass` is given: the **hidden** top-level windows that are unowned,
     have a non-empty title and whose class name matches one of the patterns (`-like`,
     case-insensitive).
  Never to any other hidden window. Use `EnumWindows` + `GetWindowThreadProcessId` +
  `PostMessage`, via a guarded `Add-Type`; re-running in one session must not fail.
- Polls until every target is gone or `TimeoutSec` elapses.
- Close-to-tray apps: after the first round, if a target is still alive, recompute the
  targets with the same rule and post `WM_CLOSE` once more to windows that were not posted
  to before (a window that was visible and is now hidden qualifies only through
  `-HiddenWindowClass`). Keep waiting inside the same total timeout.

Note: posting `WM_CLOSE` to the framework's hidden helper windows of a WinForms
process (the parking window `WindowsForms10.Window.0.*`) ended the process without running
`FormClosing`, so unsaved-changes prompts were skipped. Real apps show the same family of
helper windows: Qt (`...TrayIconMessageWindowClass`, `...ThemeChangeObserverWindow`,
`_q_titlebar`, which carry a title bar style, so style bits do not tell them apart), WinForms
(`.NET-BroadcastEventWindow`, `GDI+ Hook Window Class`), Chromium (`Chrome_WidgetWin_0`,
`Base_PowerMessageWindow`) and IME windows. That is why hidden windows are opt-in by class.
- **Never kills.** No `Stop-Process`, no `taskkill`, no `CloseMainWindow`. A process with
  no top-level window ends as `timeout`.

Tests need real fixtures: compile tiny executables with
`Add-Type -OutputAssembly <tmp>\gwm-fixture-<guid>.exe -OutputType WindowsApplication`
so each has a unique process name. Behaviours: exits on close, cancels close (ignores),
hidden window that exits on close, close-to-tray (first close hides, second exits). Keep the
raw user32 fixtures AND add real WinForms fixtures with the framework's own helper windows,
which is what proves the targeting rule: a WinForms form that cancels closing must run its
`FormClosing` handler (marker file) and stay alive, and a hidden WinForms main window is
closed only when `-HiddenWindowClass` names its class.
Required cases: not running; honours close and the fixture proves it exited through its
close handler (for example by writing a marker file there); ignores close -> `timeout`
within the timeout and the process is still alive afterwards; hidden window; close-to-tray;
timeout parameter respected; a different process whose name only starts with the target
name is untouched. The test stops its own fixtures by PID in cleanup.

## 6. User-session tasks (`src/lib/UserTasks.ps1`, `src/tasks/*`)

For every manifest app with `Policy = close-reopen` and `Scope = machine` there are two
tasks that run **as the desktop user**, interactive token, limited run level, no trigger:
`<Process>-close` and `<Process>-open`, in the manifest's `TaskFolder`.

```
Get-GwmTaskName -App <hashtable> -Action close|open               -> '<Process>-<action>'
New-GwmTaskSpec -App -Action -UserSid <string> -TasksDir <string> -TaskFolder <string>
                [-ExePath <string>] [-TimeoutSec <int> = 60]       -> [pscustomobject]
Register-GwmTasks   -Apps <hashtable[]> -UserSid -TasksDir -TaskFolder [-UserContext] -> specs registered
Unregister-GwmTasks -Apps <hashtable[]> -TaskFolder               -> nothing; silent if absent
Test-GwmInteractiveSession                                        -> [bool] (an explorer.exe exists)
Invoke-GwmTask -App <hashtable> -Action close|open [-TaskFolder <string> = '\wau-graceful-mods\']
               [-TimeoutSec <int> = 30] [-PollMs <int> = 500]       -> [pscustomobject]
```

`-TaskFolder` exists so tests can point at a throwaway folder; production callers pass the
manifest's `TaskFolder`.

`New-GwmTaskSpec` is pure and returns: `TaskPath`, `TaskName`, `Execute`
(`$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe`, full path), `Arguments`
(`-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "<TasksDir>\Invoke-<Close|Open>Task.ps1" -ProcessName "<Process>"` plus `-TimeoutSec <n>` for close or
`-ExePath "<path>"` for open), `UserSid`, `LogonType` = `Interactive`, `RunLevel` =
`Limited`, `MultipleInstances` = `IgnoreNew`, `ExecutionTimeLimit` [timespan].

`Register-GwmTasks` is idempotent (replace if present), skips apps that are not
machine-scope close-reopen, resolves each open task's exe with `Resolve-GwmExe` and skips
that task with a log line when it cannot be resolved.

`Invoke-GwmTask` returns `Started` [bool], `Completed` [bool], `Result` [int], `Reason`:
`done` | `no-task` | `not-ready` | `launch-failed` | `timeout` | `no-session`.
Rules: no interactive session -> `no-session`, nothing started. The task must exist and be
`Ready`; otherwise nothing is started (`no-task` / `not-ready`). Record the time before
`Start-ScheduledTask` (it is asynchronous). Completion (as implemented): the
scheduler truncates `LastRunTime` to whole seconds, so it must be later than the value read
before the start **and** at or after the start floored to the second; the final read must
also show state `Ready` and a result other than 267009 (task still running). `Result` is
`LastTaskResult`, and -1 for every outcome other than `done`. On timeout call
`Stop-ScheduledTask` and return `timeout` with `Completed` false. A transient miss reading
the task shows up as `no-task` (fail safe: nothing is started, the update waits for the next
logon). `Register-GwmTasks` settings: start on battery allowed, not stopped on battery,
`ExecutionTimeLimit` = `TimeoutSec` + 60 s for close and 60 s for open. `Unregister-GwmTasks`
removes the tasks and leaves the (empty) task folder; the uninstaller deletes that folder
when it is empty.

Wrappers (run inside the user session):

- `Invoke-CloseTask.ps1 -ProcessName <string> [-TimeoutSec <int> = 30] [-ManifestPath <string>]`:
  looks the app up by `Process` (case-insensitive) in the manifest (`ManifestPath` defaults
  to `$PSScriptRoot\..\apps.psd1`; a missing or unreadable manifest is logged and the close
  goes ahead without hidden-window patterns), calls `Close-App` with that app's
  `HiddenWindowClass`; `exit 0` when `Exited`, `exit 1` otherwise.
- `Invoke-OpenTask.ps1 -ProcessName <string> -ExePath <string>`: `exit 0` if the process is
  already running (idempotent, no second instance) or after `Start-Process` of the exe;
  `exit 2` if the exe does not exist; `exit 3` if starting it throws.
- Each wrapper dot-sources `..\lib\<file>.ps1` **only when the function it needs is not
  already defined**, so tests can predefine a fake.

Scheduler integration tests use a throwaway `TaskFolder` containing a GUID and remove it
afterwards. They must not need elevation (a task for the current user, interactive, limited).

## 7. Reopen marker and mod logic

`ReopenMarker.ps1` (state directory `Get-GwmStateDir`; `$env:GWM_STATE_DIR` wins, tests
set it to a temp folder):

```
Get-GwmStateDir                              -> string, created if missing
Set-GwmReopenOwed   -ProcessName <string>    -> writes reopen-<name>.json {process, owedAtUtc}
Get-GwmReopenOwed                            -> [string[]] sorted process names (corrupt files ignored + logged)
Clear-GwmReopenOwed -ProcessName <string>    -> silent if absent
```

`ModLogic.ps1`. The code under test must run against **faked** `Close-App`,
`Invoke-GwmTask`, `Test-GwmProcessRunning`, `Resolve-GwmExe`, `Start-Process` (define stubs
with the contract signatures, then `Mock`). Do not launch real apps.

```
Test-GwmMajorUpgrade -InstalledVersion <string> -AvailableVersion <string> [-App <hashtable>] [-UserContext]
    -> [bool] $true when the available major is greater than the installed major, or when
       the installed major cannot be determined (empty, or starting with '<' as winget prints
       for unknown installs; then try the exe's file version via Resolve-GwmExe) - conservative.
Backup-GwmAppData -App <hashtable> [-UserContext] [-BackupRoot <string>] [-Keep <int> = 2]
    -> destination path; copies Expand-GwmPath(App.BackupOnMajorUpgrade) to
       <BackupRoot>\<Process>-<yyyyMMdd-HHmmss>, then prunes to the newest -Keep; throws on failure.
Invoke-GwmReopen -App <hashtable> [-UserContext] [-TaskFolder <string>] -> [bool]
    machine scope: Invoke-GwmTask -Action open, success = Completed and Result 0.
    user scope: Start-Process of Resolve-GwmExe as the current user; already running = success.
                Refuses ($false, logged) when the caller runs as SYSTEM: a user-scope exe lives in
                a user-writable folder and must never be launched as SYSTEM.
Invoke-GwmPreInstall  -AppId <string> [-InstalledVersion <string>] [-AvailableVersion <string>]
                      [-ManifestPath <string>] [-TimeoutSec <int> = 60]            -> [bool]
Invoke-GwmPostInstall -AppId <string> -Succeeded <bool> [-ManifestPath <string>]   -> [bool] always $true
Invoke-GwmReconcile   [-ManifestPath <string>]                                     -> [int] reopened
Wait-GwmSettle        [-ManifestPath <string>] [-MaxWaitSec <int> = 300] [-PollSec <int> = 5]
    -> [pscustomobject] Settled [bool], WaitedSec [int], Missing [string[]]
```

`Invoke-GwmPreInstall` returns `$true` = WAU proceeds, `$false` = skip this app now:

1. App not in the manifest -> `$true`.
2. `skip-if-open`: process running -> `$false`; else `$true`.
3. `close-reopen`: process not running -> `$true`, no marker. Running -> `Set-GwmReopenOwed`,
   then close: machine scope `Invoke-GwmTask -Action close`; user scope `Close-App`. Exited
   means task `Completed` with `Result` 0, or the process is gone. Not exited ->
   `Clear-GwmReopenOwed`, return `$false` (the app keeps running; the update waits for the
   next logon). Exited, and the app has `BackupOnMajorUpgrade` and `Test-GwmMajorUpgrade`
   -> `Backup-GwmAppData`; if that throws, `Invoke-GwmReopen`, clear the marker on success
   and return `$false`. Otherwise return `$true` (the marker stays until the reopen).

`Invoke-GwmPostInstall`: for a `close-reopen` app that has a marker, `Invoke-GwmReopen`;
clear the marker only when the reopen succeeded. `Succeeded` is only logged. Other apps:
no-op.

`Invoke-GwmReconcile`: for each owed process, find its app; running -> clear the marker;
not running -> reopen and clear on success; unknown process -> clear and log.

`Wait-GwmSettle`: settled when an interactive shell exists (`Test-GwmInteractiveSession`)
and every manifest app with `Autostart = $true` has its process running. Reaching
`MaxWaitSec` is not an error: log the missing ones and return `Settled` false.

Every `Invoke-GwmTask` call from this file passes `-TaskFolder $manifest.TaskFolder`.
The machine-scope close waits `TimeoutSec + 20` seconds for the task, so the wrapper inside the
task (which waits `TimeoutSec`) decides the outcome and the 20 s cover task start and
PowerShell startup in the user session.

Path defaults (runtime only; tests pass explicit paths): `ManifestPath` =
`<parent of lib>\apps.psd1`, user context = `<parent of lib>\context.json`.

In the user-scope path `Invoke-GwmPreInstall` calls `Close-App` with the app's
`HiddenWindowClass`.

`src/mods/_WAU-mods.ps1` is the global mod: dot-source `gwm\lib\Load.ps1`, then
`Wait-GwmSettle`, then `Invoke-GwmReconcile`. WAU captures this mod's output and exit code
(`Test-WAUMods.ps1`): exit code 1 makes WAU re-run, and anything in the output that looks
like `{...}` is parsed as an action. So the script must emit **nothing** on any stream that
reaches the pipeline, and must finish with `$LASTEXITCODE` 0 and no uncaught error.

## 8. Installer (`install/*`)

Helpers (pure or file-system only, all testable without elevation):

```
Test-GwmElevated                                         -> [bool]
New-GwmWauMsiArguments [-Options <hashtable>]            -> string, stable order
    defaults: UPDATESATLOGON=1 UPDATESINTERVAL=Never USERCONTEXT=1 USEWHITELIST=1
              NOTIFICATIONLEVEL=Full DISABLEWAUAUTOUPDATE=1
ConvertTo-GwmWhitelistText -Manifest                     -> one id per line, sorted, trailing newline
New-GwmThinModContent -App <hashtable> -Kind preinstall|installed|notinstalled -> string
Write-GwmThinMods -Manifest -ModsDir                     -> [string[]] paths written
    skip-if-open apps: preinstall only; close-reopen apps: all three kinds.
Test-GwmPathAcl -Path [-Recurse]                         -> [pscustomobject] Path, Safe [bool], Offenders [object[]]
    -Recurse also checks every item inside the target and reports a directory it cannot list
    as an offender with Identity '(unreadable)' (fail closed).
Get-GwmAccessControl -Path / Set-GwmAccessControl -Path -Acl   thin wrappers over the .NET
    FileSystem ACL calls; Test-GwmPathAcl reads through them because Get-Acl fails with
    "Access is denied" on a folder the caller was locked out of.
Test-GwmQbtExitConfirm -IniPath                          -> [pscustomobject] Found, ExitConfirm [bool], Source 'ini'|'default'
Get-GwmWauInstallDir                                     -> string or $null
Get-GwmInteractiveUser                                   -> [pscustomobject] UserSid, ProfilePath, Name (owner of explorer.exe)
Copy-GwmRuntime -RepoRoot -WauDir                        -> [string[]] files copied (layout in section 3)
Protect-GwmDataDirs -Root <string>                       -> [pscustomobject] Root, Created [string[]], OwnerFixed [bool], Safe [bool]
```

`Protect-GwmDataDirs`: `%ProgramData%\wau-graceful-mods` sits under a
folder where standard users may create subfolders, so a user could pre-create it and plant
reopen markers or read the eM Client backups. The function creates `<Root>\state` and
`<Root>\backups` when missing, and on `<Root>` and both folders removes inheritance and
grants full control to SYSTEM and Administrators only; when elevated it also sets the owner
to Administrators (`OwnerFixed`). `Safe` is the result of `Test-GwmPathAcl` afterwards. The
installer calls it with `%ProgramData%\wau-graceful-mods` before any other step that writes
there, fails loudly when `Safe` is false or, since a real run is always elevated, when
`OwnerFixed` is false (an owner can rewrite the permissions), and lists the step in
`-DryRun`. Junctions and other reparse points at the root, at either folder or anywhere
inside the tree are refused. Tests use a temp folder the test owns; the owner step is
skipped when not elevated. Under a user profile `Safe` is false by construction (the
user's FullControl on every ancestor counts as an offender), so tests assert on the
target-scope offenders; `Safe` true is proved only by the elevated install run under
`%ProgramData%`.

- The MSI property names above are those of WAU's `Sources/Wix/build.wxs`. The whitelist
  file is `included_apps.txt` in the WAU folder (read by `Get-IncludedApps.ps1`).
- `Test-GwmPathAcl` rights matrix. Offender = an Allow entry for a principal other than
  SYSTEM, Administrators, TrustedInstaller and CREATOR OWNER that grants any of: on the
  target and everything inside - write data, create files, append data, create folders,
  write attributes or extended attributes, delete, delete child, change permissions, take
  ownership, full control, modify; on each ancestor up to the drive root - only delete,
  delete child, change permissions, take ownership, full control. `Safe` is true when
  there are no offenders. `Test-GwmPathAcl -Path $env:ProgramFiles` must be Safe.
- `Test-GwmQbtExitConfirm`: the effective value is `$true` when the key
  `Preferences\General\ExitConfirm` (ini section `[Preferences]`, key `General\ExitConfirm`)
  is absent (Source `default`); an explicit `false` or `true` is read from the ini.
- `Install-WauGracefulMods.ps1 [-DryRun] [-ManifestPath]`: with `-DryRun` it prints the plan
  and changes nothing, and works unelevated. Without it, it refuses to run unelevated, and
  refuses when the elevated identity is not the desktop user. Steps: `winget install
  --id Romanitho.Winget-AutoUpdate --exact --silent` with the MSI arguments through
  `--override`; locate the WAU directory; write the whitelist; `Copy-GwmRuntime`;
  `Write-GwmThinMods`; `Save-GwmUserContext`; `Register-GwmTasks`; `Test-GwmPathAcl` on the
  runtime directory (fail loudly when not Safe); `Test-GwmQbtExitConfirm` (warn when
  `ExitConfirm` is on); print what changed. Re-running is safe.
- `Uninstall-WauGracefulMods.ps1 [-DryRun] [-RemoveWau]`: removes only what the installer
  created (it records the files in `installed-files.json`), unregisters the tasks, and
  optionally uninstalls WAU.
- The test suite never installs, uninstalls or registers anything for the machine: it uses
  throwaway folders and `-DryRun`.
