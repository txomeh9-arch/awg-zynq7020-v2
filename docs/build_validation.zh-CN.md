# V2 构建与验证记录

本记录区分仿真/静态检查与实板测量。执行环境为 Windows 11、Vivado/Vitis 2026.1，目标器件 XC7Z020CLG484-1。

| 项目 | 当前结果 | 证据与限制 |
|---|---|---|
| 波形通道 RTL 仿真 | 通过 | `sim/run.ps1`：48 位 DDS 相位、突发、奇数长度 BRAM 回绕、运行中分频边界、DDR 精确有限次和欠载 |
| PL 集成仿真 | 通过 | `sim/run_pl.ps1`：跨域命令、同步 FIFO 清空、复位后安全空闲/重新通信；新增 10/25/50 MSPS 连续数据跳变到 WRT/CLK 上升沿的名义相位检查 |
| 协议与固件单元测试 | 15 项通过 | `python -m pytest -q -p no:cacheprovider tests`；包含百万点上传、CRC 错帧、整段 CRC 错误后同数据重传、时钟失锁不发超时命令、重复请求、控制会话冲突，但不代表实网口测试 |
| Vivado 工程流 | 已在本地生成当前源码位流和完整 XSA | 2026-09-30 10:19，综合、布局布线、位流与 XSA 导出成功；生成路径为 `build/awg_v2.bit` 与 `build/awg_v2_complete.xsa`，均不提交到仓库；`scripts/check_hwh.py` 验证 MMIO 地址与 512 MiB DDR 窗口 |
| 实现后静态时序 | 已约束路径通过 | 本地生成的 `reports/timing_summary.rpt`：WNS +0.200 ns、WHS +0.050 ns、TNS/THS 0；仅代表现有约束模型 |
| DRC | 无阻断错误 | 本地 `reports/drc.rpt` 仍有 65 条警告，主要为 IP 流水线和 RAM 异步控制；上板前需复核 |
| CDC | **未通过完整验收** | 本地 `reports/cdc.rpt` 有 9 条 Critical，全部位于 GMII-to-RGMII/PS 接口；本工程 PL 逻辑 Critical 为 0。逐项见 [CDC 复核](cdc_review.zh-CN.md) |
| 外部时序完整性 | **未通过验收** | 本地 `reports/check_timing.rpt` 仍缺 MDIO 输入延迟及 DAC CLK/WRT、标记输出的外部模型；厂商网口时钟复用还有 1 个 multiple_clock 提示。需要结合实际板卡、杜邦线和 DAC 端测量补全 |
| Vitis 固件 ELF | 尚未生成 | 完整 XSA 可由独立 `sdtgen` 解析；本机 Vitis 平台生成仍报 `Error in generating SDT` / `Invalid project location`，且缺 ARM 工具链。见 [环境说明](vitis_setup.zh-CN.md) |
| DDR、千兆网口、DMA、DAC 模拟输出 | 未上板测量 | 接线、下载、校准与长时间吞吐验收均待实物操作 |
| 后级功放联调 | 未进行 | 需先确认完整型号、输入电压范围、极性和带宽 |

当前仿真不能证明杜邦线上的 10/25/50 MSPS 数据、WRT、CLK 到达 DAC 端时仍满足建立与保持时间。三档均需在实际接线条件下测量；50 MSPS 不因低速通过而自动视为通过。位流和 XSA 已在本地生成，但 CDC 与外部时序尚未达到计划中的最终验收条件，暂不将其视为可直接连接功放的硬件版本。

本仓库仅包含 V2 工程，第一版单独保存。实测数据填写在 [实测记录](measurements.zh-CN.md)。

上述 Vivado 报告与位流属于本地构建记录，不纳入 Git；从仓库克隆后须按 README 重新生成。报告数值不保证在其他工具安装、器件速度档位或约束更改后保持相同。
