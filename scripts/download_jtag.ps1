$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'tool_paths.ps1')
$xsdb = Join-Path (Get-AwgToolHome Vivado) 'bin/xsdb.bat'
$bit = Join-Path $root 'build/awg_v2.bit'
$vitisBuild = Join-Path $root 'build/vitis'
if (-not (Test-Path -LiteralPath $bit)) { throw "位流不存在：$bit" }
if (-not (Test-Path -LiteralPath $vitisBuild)) { throw "Vitis 工程不存在：$vitisBuild" }
$init = Get-ChildItem -LiteralPath $vitisBuild -Recurse -File -Filter 'ps7_init.tcl' |
    Select-Object -First 1 -ExpandProperty FullName
$elf = Get-ChildItem -LiteralPath $vitisBuild -Recurse -File -Filter 'awg_firmware.elf' |
    Select-Object -First 1 -ExpandProperty FullName
if (-not $init -or -not $elf) { throw '未找到 ps7_init.tcl 或 awg_firmware.elf；请先构建固件' }
Set-Location $root
& $xsdb scripts/download_jtag.tcl $init $elf $bit
if ($LASTEXITCODE -ne 0) { throw 'JTAG 下载失败' }
