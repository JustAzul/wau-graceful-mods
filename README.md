# wau-graceful-mods

Mods for [Winget-AutoUpdate](https://github.com/Romanitho/Winget-AutoUpdate) (WAU) that
update a fixed list of apps at logon without losing work. For apps that stay open, such as
a torrent client or a mail client, the mods close the app gracefully, skip the update when
the app will not exit, and reopen it as the desktop user afterwards.

WAU runs as SYSTEM in session 0, so it cannot ask a window in your desktop session to close,
and it force-kills a process only when a mod tells it to. This kit fills that gap with
per-app scheduled tasks that run as you.

## What it does

- Installs WAU from winget with logon-only updates and whitelist mode, and writes the
  whitelist from `config/apps.psd1`.
- Generates a thin pre-install, installed and not-installed mod per app that needs special
  handling, plus one global mod that reopens anything that was closed and never came back.
- Closes an app by posting `WM_CLOSE` to its windows from a scheduled task that runs in your
  session. The app's own close handler runs, so it can save its state. It never kills a
  process.
- When the app does not exit within the timeout, it keeps running and its update waits for
  the next logon.
- Reopens the app as you after the update, or after a failed update.
- Before a major version upgrade, copies the data folder listed for the app into
  `%ProgramData%\wau-graceful-mods\backups` and keeps the newest two.
- Locks `%ProgramData%\wau-graceful-mods` to SYSTEM and Administrators, because it holds
  files that SYSTEM reads.

## Apps

The list lives in `config/apps.psd1`; edit it and run the installer again.

| Policy | Meaning |
|---|---|
| `close-reopen` | close gracefully, update, reopen as the user |
| `skip-if-open` | leave the update for the next logon while the app runs |
| default | whitelisted only: WAU's normal flow, no mod |

Keys per app: `Id` (winget id), `Process`, `Scope` (`machine` or `user`), `Policy`, `Exe`
(candidate paths, required for `close-reopen`), `Autostart`, `BackupOnMajorUpgrade`,
`HiddenWindowClass`. The key reference is in [docs/DESIGN.md](docs/DESIGN.md), section 4.

`HiddenWindowClass` names the class pattern of an app's own main window when it lives hidden
in the tray. Closing otherwise targets visible windows only, because a hidden helper window
of a UI framework can end the process without running the app's close handler.

## Install

Requirements: Windows with winget, Windows PowerShell 5.1, and an elevated prompt opened by
the account you use at the desktop.

```powershell
# Preview first: prints the plan and changes nothing, works without elevation.
.\install\Install-WauGracefulMods.ps1 -DryRun

# Install (elevated).
.\install\Install-WauGracefulMods.ps1
```

The installer is safe to run again. It stops before changing anything when a preflight check
fails (not elevated, no desktop session, repository files missing). Later checks stop it with
a message when WAU was installed without whitelist mode, or when the files SYSTEM will run
could be written by a non-administrator.

If an app asks for confirmation on exit, its close request is answered by a dialog and the
update waits for the next logon. For qBittorrent, turn off Tools > Options > Behavior >
Confirm when exiting; the installer warns when the setting is on.

## Uninstall

```powershell
.\install\Uninstall-WauGracefulMods.ps1 -DryRun
.\install\Uninstall-WauGracefulMods.ps1             # keeps WAU
.\install\Uninstall-WauGracefulMods.ps1 -RemoveWau  # removes WAU too
```

It deletes only the files the installer recorded and unregisters the scheduled tasks. Reopen
markers and backups under `%ProgramData%\wau-graceful-mods` stay.

## Development

Tests are Pester 3.4 on Windows PowerShell 5.1. From WSL:

```bash
scripts/run-tests.sh                       # whole suite
scripts/run-tests.sh tests/Manifest.Tests.ps1
```

The runner copies the repository to a private Windows temp folder for each run, so parallel
runs do not share a working copy. `scripts/pii-scan.sh` checks tracked and untracked files
for personal data before a push. The design the code follows is in
[docs/DESIGN.md](docs/DESIGN.md).

## License

MIT.
