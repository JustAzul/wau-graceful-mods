# Logging helper shared by every library file.
# Inside a WAU run it forwards to WAU's own Write-ToLog; elsewhere it is verbose output.
# It never writes to the success pipeline, so mod entry points can return a single value.

function Write-GwmLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Message
    )

    $line = "[gwm] $Message"
    if (Get-Command -Name Write-ToLog -ErrorAction SilentlyContinue) {
        Write-ToLog $line | Out-Null
    }
    else {
        Write-Verbose $line
    }
}
