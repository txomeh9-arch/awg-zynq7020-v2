function Get-AwgToolHome {
    param([ValidateSet('Vivado', 'Vitis')][string]$Tool)

    $override = if ($Tool -eq 'Vivado') { $env:AWG_VIVADO_HOME } else { $env:AWG_VITIS_HOME }
    $vendor = if ($Tool -eq 'Vivado') { $env:XILINX_VIVADO } else { $env:XILINX_VITIS }
    $name = if ($Tool -eq 'Vivado') { 'vivado.bat' } else { 'vitis.bat' }
    if ($override) { $toolRoot = $override }
    elseif ($vendor) { $toolRoot = $vendor }
    else {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if (-not $command) {
            throw "找不到 $name；请将其 bin 目录加入 PATH，或设置 AWG_$($Tool.ToUpper())_HOME"
        }
        $toolRoot = Split-Path -Parent (Split-Path -Parent $command.Source)
    }
    $toolRoot = (Resolve-Path -LiteralPath $toolRoot -ErrorAction Stop).Path
    $binary = Join-Path $toolRoot "bin/$name"
    if (-not (Test-Path -LiteralPath $binary)) { throw "工具不存在：$binary" }
    return $toolRoot
}
