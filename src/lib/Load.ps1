# Dot-source this file to get every library function:
#
#   . "<runtime>\gwm\lib\Load.ps1"
#
# Files are loaded in dependency order and a file that is not installed is
# skipped, so a partial checkout still loads what it has.

$gwmLibDir = Split-Path -Parent $MyInvocation.MyCommand.Path

foreach ($gwmLibName in 'Log', 'Manifest', 'Process', 'CloseApp', 'UserTasks', 'ReopenMarker', 'ModLogic') {
    $gwmLibFile = Join-Path $gwmLibDir ($gwmLibName + '.ps1')
    if (Test-Path -LiteralPath $gwmLibFile) {
        . $gwmLibFile
    }
}
