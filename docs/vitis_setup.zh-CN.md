# Vitis 2026.1 固件构建环境

一次本地构建中，Vivado 已生成带位流和 `ps7_init.tcl` 的完整 XSA，但尚未生成 Cortex-A9 ELF。`scripts/build_firmware.ps1` 在 Vitis `create_platform_component` 阶段收到 `Error in generating SDT` / `Invalid project location`。以另一工作目录和 Vitis 内置 `zc702` 硬件设计重试也出现相同错误。进一步用 Vivado 自带的 `sdtgen.bat -xsa ... -dir ...` 单独处理本工程完整 XSA，已成功生成 `system-top.dts`、`pl.dtsi`、`pcw.dtsi` 和 `ps7_init.c`；说明 XSA 至少能被设备树生成器解析，失败集中在 Vitis 平台创建流程。当时的工具安装仅发现 MicroBlaze 与 RISC-V GNU 工具链，未找到 ARM 交叉编译器。其他环境应独立检查，不应直接套用此结论。

修复安装时，在 AMD Unified Installer 2026.1 中检查 Vitis Embedded、Zynq-7000 器件系列和 ARM GNU 工具链是否选中。AMD [安装指南](https://docs.amd.com/r/en-US/ug973-vivado-release-notes-install-license/Run-the-Installation-File)说明安装器可按器件系列和设计工具定制安装。将 Vivado/Vitis 的 `bin` 目录加入 `PATH`，或设置 `AWG_VIVADO_HOME` / `AWG_VITIS_HOME`；如系统设备树仓库位于非标准位置，设置 `AWG_SDT_REPO`。完成后先确认 ARM 编译器可运行，再执行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/export_complete_xsa.ps1
powershell -ExecutionPolicy Bypass -File scripts/build_firmware.ps1
```

若安装完成后仍出现 `Invalid project location`，先在新的 Vitis 工作区尝试内置 `zc702` 平台，以区分本机 Vitis 服务问题和本工程 XSA 问题。不要把现有 XSA、位流或 Windows 原生 C 单元测试当作已经生成或验证过的 Cortex-A9 ELF。上板前还须用 JTAG 下载并完成 DDR、网口和 DAC 实测。
