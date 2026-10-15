# Reopen markers: a process name written here means "this app was closed for an update
# and owes a reopen". One reopen-<name>.json file per process in the state directory.

function Get-GwmStateDir {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $dir = $env:GWM_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) {
        $dir = Join-Path $env:ProgramData 'wau-graceful-mods\state'
    }
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $dir
}

function Test-GwmMarkerName {
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$ProcessName)

    # A plain file-name fragment only: no separators, no dots at the start, nothing that
    # could step out of the state folder.
    [bool]($ProcessName -match '^[A-Za-z0-9][A-Za-z0-9._ +-]*$')
}

function Get-GwmMarkerPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$ProcessName)

    if (-not (Test-GwmMarkerName -ProcessName $ProcessName)) {
        throw "Invalid process name for a reopen marker: '$ProcessName'"
    }
    Join-Path (Get-GwmStateDir) ('reopen-{0}.json' -f $ProcessName)
}

function Set-GwmReopenOwed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName
    )

    $path = Get-GwmMarkerPath -ProcessName $ProcessName
    $json = [pscustomobject]@{
        process    = $ProcessName
        owedAtUtc  = [datetime]::UtcNow.ToString('o')
    } | ConvertTo-Json

    # Write beside the target and move into place so a reader never sees half a file.
    $partial = $path + '.tmp'
    Set-Content -LiteralPath $partial -Value $json -Encoding ASCII
    Move-Item -LiteralPath $partial -Destination $path -Force
}

function Get-GwmReopenOwed {
    [CmdletBinding()]
    [OutputType([string[]])]
    param()

    $names = New-Object System.Collections.Generic.List[string]
    $files = @(Get-ChildItem -LiteralPath (Get-GwmStateDir) -Filter 'reopen-*.json' -File -ErrorAction SilentlyContinue)
    foreach ($file in $files) {
        try {
            $data = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $name = $null
            if ($null -ne $data -and $null -ne $data.PSObject.Properties['process']) {
                $name = [string]$data.process
            }
            if (-not (Test-GwmMarkerName -ProcessName $name)) {
                throw 'no usable process name'
            }
            if ($file.Name -ne ('reopen-{0}.json' -f $name)) {
                throw 'process name does not match the file name'
            }
            $names.Add($name)
        }
        catch {
            Write-GwmLog "Ignoring unreadable reopen marker $($file.Name): $($_.Exception.Message)"
        }
    }

    # Callers wrap the call in @() so zero or one names still behave as an array.
    [string[]]@($names | Sort-Object)
}

function Clear-GwmReopenOwed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$ProcessName
    )

    $path = Get-GwmMarkerPath -ProcessName $ProcessName
    Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
}
