$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'tool_paths.ps1')
$vivado = Join-Path (Get-AwgToolHome Vivado) 'bin/vivado.bat'
$env:XILINX_LOCAL_USER_DATA = 'no'
Set-Location $root
& $vivado -mode batch -source scripts/create_project.tcl -nolog -nojournal
if ($LASTEXITCODE -ne 0) { throw 'Vivado block-design creation failed' }
& $vivado -mode batch -source scripts/build.tcl -nolog -nojournal
if ($LASTEXITCODE -ne 0) { throw 'Vivado implementation failed' }
