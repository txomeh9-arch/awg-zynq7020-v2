$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'tool_paths.ps1')
$vivado = Join-Path (Get-AwgToolHome Vivado) 'bin/vivado.bat'
$env:XILINX_LOCAL_USER_DATA = 'no'
Set-Location $root
& $vivado -mode batch -source scripts/export_complete_xsa.tcl -nolog -nojournal
if ($LASTEXITCODE -ne 0) { throw '完整 XSA 导出失败' }
