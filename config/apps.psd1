# Live app list for wau-graceful-mods.
# Loaded with Import-PowerShellDataFile, so this file is data only and cannot run code.
@{
    SchemaVersion = 1

    # Task Scheduler folder that holds the per-app close and open tasks.
    TaskFolder = '\wau-graceful-mods\'

    # Winget id of the updater itself. It is whitelisted so winget updates it
    # with the installer hash from the winget manifest.
    SelfId = 'Romanitho.Winget-AutoUpdate'

    # Apps that need a per-app policy.
    #   Scope  machine : installed for all users, updated by WAU's SYSTEM pass
    #          user    : installed per user, updated by WAU's user-context pass
    #   Policy close-reopen : close gracefully, update, reopen as the user
    #          skip-if-open : leave the update for the next logon while the app runs
    #   Process   : process name without .exe
    #   Exe       : candidate paths for the executable, first existing wins (close-reopen only)
    #   Autostart : the app starts by itself at logon, so the updater waits for it
    #   BackupOnMajorUpgrade : folder copied before the major version changes
    #   HiddenWindowClass : class name patterns (-like) of the app's own main window when it
    #                       lives hidden in the tray. Closing normally targets visible windows
    #                       only; these patterns add the hidden main window and nothing else,
    #                       because framework helper windows can end the process abruptly.
    # eM Client is left out on purpose: it stays in the tray on a close request, and version 11 is a
    # major upgrade packaged as MSIX, so its executable path changes. Add it back only with a close
    # method that makes it exit and a reopen that follows the new package.
    Apps = @(
        @{
            Id                = 'qBittorrent.qBittorrent'
            Process           = 'qbittorrent'
            Scope             = 'machine'
            Policy            = 'close-reopen'
            Autostart         = $true
            Exe               = @('%ProgramFiles%\qBittorrent\qbittorrent.exe')
            HiddenWindowClass = @('Qt*QWindowIcon')
        },
        @{
            Id        = 'Obsidian.Obsidian'
            Process   = 'Obsidian'
            Scope     = 'user'
            Policy    = 'close-reopen'
            Autostart = $false
            Exe       = @('%LOCALAPPDATA%\Programs\Obsidian\Obsidian.exe')
        },
        @{
            Id      = 'Microsoft.VisualStudioCode'
            Process = 'Code'
            Scope   = 'user'
            Policy  = 'skip-if-open'
        },
        @{
            Id      = 'DBeaver.DBeaver.Community'
            Process = 'dbeaver'
            Scope   = 'user'
            Policy  = 'skip-if-open'
        },
        @{
            Id      = '3TSoftwareLabs.Studio3T'
            Process = 'Studio 3T Community Edition'
            Scope   = 'machine'
            Policy  = 'skip-if-open'
        }
    )

    # Whitelisted apps that follow WAU's default flow (no per-app mod).
    DefaultApps = @(
        '7zip.7zip',
        'RARLab.WinRAR',
        'VideoLAN.VLC',
        'Git.Git',
        'AgileBits.1Password.CLI',
        'Microsoft.WindowsTerminal',
        'Microsoft.AppInstaller',
        'Microsoft.VCRedist.2013.x64',
        'Microsoft.VCRedist.2013.x86'
    )
}
