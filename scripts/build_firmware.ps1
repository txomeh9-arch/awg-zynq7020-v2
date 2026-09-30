$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'tool_paths.ps1')
$env:AWG_VITIS_HOME = Get-AwgToolHome Vitis
$vitis = Join-Path $env:AWG_VITIS_HOME 'bin/vitis.bat'
$env:XILINX_LOCAL_USER_DATA = 'no'
Set-Location $root
$priorErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $output = & $vitis -s scripts/build_firmware.py 2>&1
    $vitisExitCode = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $priorErrorAction
}
$output
if ($vitisExitCode -ne 0 -or (($output -join "`n") -notmatch 'AWG_V2_FIRMWARE_BUILD_COMPLETE')) {
    throw 'Vitis firmware build failed (no success marker)'
}
