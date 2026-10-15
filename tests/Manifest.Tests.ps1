$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'src\lib\Log.ps1')
. (Join-Path $root 'src\lib\Manifest.ps1')

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

Describe 'Import-GwmManifest' {
    AfterEach { Remove-TempFiles }

    Context 'the shipped manifest' {
        $m = Import-GwmManifest -Path (Join-Path $root 'config\apps.psd1')

        It 'lists apps' {
            @($m.Apps).Count | Should BeGreaterThan 0
        }
        It 'gives every app Id, Process, Scope and Policy' {
            foreach ($a in $m.Apps) {
                foreach ($k in 'Id', 'Process', 'Scope', 'Policy') {
                    $a.ContainsKey($k) | Should Be $true
                }
            }
        }
        It 'names an executable for every close-reopen app' {
            foreach ($a in $m.Apps) {
                if ($a.Policy -eq 'close-reopen') { @($a.Exe).Count | Should BeGreaterThan 0 }
            }
        }
    }

    Context 'validation' {
        It 'rejects an unknown Policy' {
            $p = New-TempFile "@{ Apps = @( @{ Id='a.b'; Process='ab'; Scope='user'; Policy='nuke' } ) }"
            { Import-GwmManifest -Path $p } | Should Throw 'Policy'
        }
        It 'rejects an unknown Scope' {
            $p = New-TempFile "@{ Apps = @( @{ Id='a.b'; Process='ab'; Scope='galaxy'; Policy='skip-if-open' } ) }"
            { Import-GwmManifest -Path $p } | Should Throw 'Scope'
        }
        It 'rejects close-reopen without Exe' {
            $p = New-TempFile "@{ Apps = @( @{ Id='a.b'; Process='ab'; Scope='user'; Policy='close-reopen' } ) }"
            { Import-GwmManifest -Path $p } | Should Throw 'Exe'
        }
        It 'accepts HiddenWindowClass patterns' {
            $p = New-TempFile "@{ Apps = @( @{ Id='a.b'; Process='ab'; Scope='user'; Policy='close-reopen'; Exe=@('x.exe'); HiddenWindowClass=@('Qt*QWindowIcon') } ) }"
            (Import-GwmManifest -Path $p).Apps[0].HiddenWindowClass[0] | Should Be 'Qt*QWindowIcon'
        }
        It 'rejects an empty HiddenWindowClass' {
            $p = New-TempFile "@{ Apps = @( @{ Id='a.b'; Process='ab'; Scope='user'; Policy='close-reopen'; Exe=@('x.exe'); HiddenWindowClass=@() } ) }"
            { Import-GwmManifest -Path $p } | Should Throw 'HiddenWindowClass'
        }
        It 'rejects a blank HiddenWindowClass pattern' {
            $p = New-TempFile "@{ Apps = @( @{ Id='a.b'; Process='ab'; Scope='user'; Policy='close-reopen'; Exe=@('x.exe'); HiddenWindowClass=@('  ') } ) }"
            { Import-GwmManifest -Path $p } | Should Throw 'HiddenWindowClass'
        }
        It 'rejects duplicate Ids regardless of case' {
            $p = New-TempFile "@{ Apps = @( @{ Id='a.b'; Process='ab'; Scope='user'; Policy='skip-if-open' }, @{ Id='A.B'; Process='ab2'; Scope='user'; Policy='skip-if-open' } ) }"
            { Import-GwmManifest -Path $p } | Should Throw 'Duplicate'
        }
        It 'does not execute code found in the file' {
            $marker = Join-Path $script:tmp ('gwm-marker-{0}' -f [guid]::NewGuid().ToString('N'))
            $p = New-TempFile "@{ Apps = @( (New-Item -ItemType File -Path '$marker') ) }"
            { Import-GwmManifest -Path $p } | Should Throw
            Test-Path -LiteralPath $marker | Should Be $false
        }
    }
}

Describe 'Get-GwmApp' {
    $m = @{ Apps = @( @{ Id = 'Vendor.App'; Process = 'app'; Scope = 'user'; Policy = 'skip-if-open' } ) }

    It 'finds an app by Id ignoring case' {
        (Get-GwmApp -Manifest $m -Id 'vendor.app').Process | Should Be 'app'
    }
    It 'returns null for an unknown Id' {
        Get-GwmApp -Manifest $m -Id 'nobody.nothing' | Should BeNullOrEmpty
    }
}

Describe 'Get-GwmWhitelist' {
    $m = Import-GwmManifest -Path (Join-Path $root 'config\apps.psd1')
    $ids = @(Get-GwmWhitelist -Manifest $m)

    It 'contains the per-app ids, the default ids and the updater itself' {
        # Pester 3.4: Should Contain reads a file, so test list membership with -contains.
        ($ids -contains 'qBittorrent.qBittorrent') | Should Be $true
        ($ids -contains '7zip.7zip') | Should Be $true
        ($ids -contains 'Romanitho.Winget-AutoUpdate') | Should Be $true
    }
    It 'has no duplicates' {
        @($ids | Select-Object -Unique).Count | Should Be $ids.Count
    }
    It 'is sorted' {
        $sorted = @($ids | Sort-Object)
        ($ids -join '|') | Should Be ($sorted -join '|')
    }
}

Describe 'Expand-GwmPath' {
    It 'expands environment variables' {
        Expand-GwmPath -Path '%SystemRoot%\x' | Should Be ($env:SystemRoot + '\x')
    }
    It 'leaves an unknown variable untouched' {
        Expand-GwmPath -Path '%GWM_NO_SUCH_VARIABLE%\x' | Should Be '%GWM_NO_SUCH_VARIABLE%\x'
    }
    It 'maps the per-user folders onto a given profile' {
        $ctx = [pscustomobject]@{ ProfilePath = 'C:\Users\fake-user' }
        Expand-GwmPath -Path '%APPDATA%\Fake App' -UserContext $ctx | Should Be 'C:\Users\fake-user\AppData\Roaming\Fake App'
        Expand-GwmPath -Path '%LOCALAPPDATA%\x' -UserContext $ctx | Should Be 'C:\Users\fake-user\AppData\Local\x'
        Expand-GwmPath -Path '%USERPROFILE%\x' -UserContext $ctx | Should Be 'C:\Users\fake-user\x'
    }
}

Describe 'Resolve-GwmExe' {
    AfterEach { Remove-TempFiles }

    It 'returns the first candidate that exists' {
        $real = New-TempFile 'x' '.exe'
        $app = @{ Exe = @('C:\gwm-does-not-exist\nope.exe', $real) }
        Resolve-GwmExe -App $app | Should Be $real
    }
    It 'returns null when no candidate exists' {
        Resolve-GwmExe -App @{ Exe = @('C:\gwm-does-not-exist\nope.exe') } | Should BeNullOrEmpty
    }
    It 'returns null for an app without Exe' {
        Resolve-GwmExe -App @{ Id = 'x' } | Should BeNullOrEmpty
    }
}

Describe 'User context file' {
    AfterEach { Remove-TempFiles }

    It 'round-trips the user sid and profile path' {
        $p = New-TempFile '' '.json'
        Save-GwmUserContext -Path $p -UserSid 'S-1-5-21-1-2-3-1001' -ProfilePath 'C:\Users\fake-user'
        $ctx = Get-GwmUserContext -Path $p
        $ctx.UserSid | Should Be 'S-1-5-21-1-2-3-1001'
        $ctx.ProfilePath | Should Be 'C:\Users\fake-user'
    }
    It 'returns null when the file is missing' {
        Get-GwmUserContext -Path (Join-Path $script:tmp 'gwm-missing-context.json') | Should BeNullOrEmpty
    }
}

Describe 'Import-GwmManifest called from another script' {
    AfterEach { Remove-TempFiles }

    It 'validates the same way when the caller is a separate script file' {
        $manifest = New-TempFile "@{ Apps = @( @{ Id='a.b'; Process='ab'; Scope='user'; Policy='skip-if-open' } ) }"
        $caller = New-TempFile 'param([string]$Path) @((Import-GwmManifest -Path $Path).Apps).Count' '.ps1'
        (& $caller -Path $manifest) | Should Be 1
    }
}
