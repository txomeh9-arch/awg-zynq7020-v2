$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $root 'scripts/tool_paths.ps1')
$vivadoHome = Get-AwgToolHome Vivado
$sim = Join-Path $root 'build\sim'
New-Item -ItemType Directory -Force -Path $sim | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'rtl\sine1024.mem') -Destination (Join-Path $sim 'sine1024.mem') -Force
Set-Location $sim
$xvlog = Join-Path $vivadoHome 'bin/xvlog.bat'
$xelab = Join-Path $vivadoHome 'bin/xelab.bat'
$xsim = Join-Path $vivadoHome 'bin/xsim.bat'
& $xvlog -sv -work xil_defaultlib (Join-Path $root 'rtl\wave_channel_v2.sv') (Join-Path $root 'sim\tb_wave_channel_v2.sv')
if ($LASTEXITCODE -ne 0) { throw 'xvlog failed' }
& $xelab xil_defaultlib.tb_wave_channel_v2 -s tb_wave_channel_v2_snapshot
if ($LASTEXITCODE -ne 0) { throw 'xelab failed' }
$runOutput = & $xsim tb_wave_channel_v2_snapshot -runall 2>&1
$runOutput
if ($LASTEXITCODE -ne 0 -or ($runOutput -match 'Fatal:')) { throw 'xsim failed' }
