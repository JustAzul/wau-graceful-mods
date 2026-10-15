# Process lookup shared by the policy code.

function Test-GwmProcessRunning {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName
    )

    # Get-Process -Name matches case-insensitively and sees every session.
    [bool](@(Get-Process -Name $ProcessName -ErrorAction SilentlyContinue).Count -gt 0)
}
