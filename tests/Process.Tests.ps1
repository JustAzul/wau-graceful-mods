$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
. (Join-Path $root 'src\lib\Log.ps1')
. (Join-Path $root 'src\lib\Process.ps1')

Describe 'Test-GwmProcessRunning' {
    It 'is true for a process that is running' {
        $own = (Get-Process -Id $PID).ProcessName
        Test-GwmProcessRunning -ProcessName $own | Should Be $true
    }
    It 'ignores the case of the name' {
        $own = (Get-Process -Id $PID).ProcessName.ToUpperInvariant()
        Test-GwmProcessRunning -ProcessName $own | Should Be $true
    }
    It 'is false when nothing carries the name' {
        Test-GwmProcessRunning -ProcessName ('gwm-none-' + [guid]::NewGuid().ToString('N')) | Should Be $false
    }
    It 'returns a single boolean' {
        $r = @(Test-GwmProcessRunning -ProcessName 'gwm-none-x')
        $r.Count | Should Be 1
        $r[0] -is [bool] | Should Be $true
    }
}

Describe 'Test-GwmRunningAsSystem' {
    It 'returns one bool and is false for the test user' {
        $r = @(Test-GwmRunningAsSystem)
        $r.Count | Should Be 1
        ($r[0] -is [bool]) | Should Be $true
        $r[0] | Should Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().IsSystem)
    }
}
