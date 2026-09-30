# 实现后 CDC 复核（2026-09-30）

本地生成的 `reports/cdc.rpt` 共有 9 条 Critical，均以 AMD `gmii_to_rgmii` IP 或 PS GEM 为终点/起点；自编 `pl_engine` 内没有剩余 Critical。报告是构建产物，不纳入 Git。此前命令应答位把 AXI GPIO 信号用作采样域异步复位值，已改为异步 FIFO 命令令牌及 AXI 域应答寄存器，PL 仿真覆盖复位时 GPIO 位为 1 后再次发命令。

| 数量 | Vivado 分类 | 位置 | 当前判断 |
|---:|---|---|---|
| 1 | CDC-10 | `rst100` 到 GMII-to-RGMII 内部复位同步电路 | IP 内部组合逻辑，需网口复位/链路实测；暂未豁免 |
| 6 | CDC-13 | GMII-to-RGMII 的速率时钟复用及内部非 FD 原语 | 其中两条到 BUFGMUX 选择端；IP 会按链路速率切换时钟，需 10/100/1000 Mb/s 链路测试；暂未豁免 |
| 2 | CDC-1 | IP 到 PS GEM 的 `GMII_COL`、`GMII_CRS` | 全双工应用预计不使用冲突/载波信号，但需确认 PS 配置与链路行为；暂未豁免 |

IP 自带 XDC 已对部分内部路径设置 `False Path`；这只影响静态时序计算，**不能自动证明 CDC 安全**。AMD [UG906 的 CDC 规则说明](https://docs.amd.com/r/en-US/ug906-vivado-design-analysis/Understanding-the-Clock-Domain-Crossings-Report-Rules)仍将 CDC-10、CDC-13 归为 Critical；[PG160 的时钟说明](https://docs.amd.com/r/en-US/pg160-gmii-to-rgmii/GMII-Transmit-Clock)说明该核按链路速率使用时钟复用。为避免掩盖问题，工程未增加覆盖这些路径的全局 `set_false_path` 或把 CDC 报告改写为“0 Critical”。

本地 `reports/check_timing.rpt` 现在没有无时钟寄存器或未约束内部端点。仍缺 MDIO 输入延迟，以及 DAC CLK/WRT 和标记输出的外部时序模型；RGMII TXC 为转发时钟。`key1_n` 和 `trigger_in` 是异步输入，已分别按复位/双级同步器处理并设置对应 false path。需要用实际板卡、PHY 与最终杜邦线测量后完善接口约束。
