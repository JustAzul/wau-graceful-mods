$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$script:loader = Join-Path $root 'src\lib\Load.ps1'
$script:tmp = [System.IO.Path]::GetFullPath($env:TEMP)

Describe 'Load.ps1' {
    It 'defines the shared functions when dot-sourced' {
        $names = & {
            . $script:loader
            @('Write-GwmLog', 'Import-GwmManifest', 'Test-GwmProcessRunning') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue }
        }
        @($names).Count | Should Be 3
    }

    It 'skips a library file that does not exist' {
        $dir = Join-Path $script:tmp ('gwm-load-{0}' -f [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            Copy-Item -LiteralPath $script:loader -Destination $dir
            Copy-Item -LiteralPath (Join-Path $root 'src\lib\Log.ps1') -Destination $dir
            $found = & {
                . (Join-Path $dir 'Load.ps1')
                [bool](Get-Command Write-GwmLog -ErrorAction SilentlyContinue)
            }
            $found | Should Be $true
        }
        finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'leaves no output on the success pipeline' {
        $out = & { . $script:loader }
        @($out).Count | Should Be 0
    }
}
