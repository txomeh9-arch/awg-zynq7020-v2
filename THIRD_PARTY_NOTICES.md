# 外部来源与移植代码

本仓库没有收录开发板、DAC 的原理图或数据手册。`docs/wiring.csv` 与 `constraints/awg_v2.xdc` 的引脚映射根据用户提供的 Smart ZYNQ SL V1.3B 和 ACM9767 原理图整理；接线前仍须按实物和原理图复核。DAC 接口时序参考 [Analog Devices AD9763/AD9765/AD9767 数据手册](https://www.analog.com/media/en/technical-documentation/data-sheets/ad9763_9765_9767.pdf)。网口桥和 CDC 分析分别参考 AMD 的 [PG160](https://docs.amd.com/r/en-US/pg160-gmii-to-rgmii/Product-Specification) 与 [UG906](https://docs.amd.com/r/en-US/ug906-vivado-design-analysis/Understanding-the-Clock-Domain-Crossings-Report-Rules)。这些资料仅用于设计与验证，没有复制进仓库。

以下三个源文件是 Vivado 2026.1 随附的 AMD/Xilinx `embeddedsw` **lwIP Echo Server** 示例的原样副本，文件头保留了原版权声明、再分发条件和免责声明：

| 本仓库文件 | 上游文件 |
|---|---|
| `firmware/platform.c` | [embeddedsw lwip_echo_server/platform.c](https://github.com/Xilinx/embeddedsw/blob/master/lib/sw_apps/lwip_echo_server/src/platform.c) |
| `firmware/platform.h` | [embeddedsw lwip_echo_server/platform.h](https://github.com/Xilinx/embeddedsw/blob/master/lib/sw_apps/lwip_echo_server/src/platform.h) |
| `firmware/platform_zynq.c` | [embeddedsw lwip_echo_server/platform_zynq.c](https://github.com/Xilinx/embeddedsw/blob/master/lib/sw_apps/lwip_echo_server/src/platform_zynq.c) |

其余 RTL、上位机、协议及构建逻辑作为本工程源码维护；Vivado/Vitis 的 IP、工具链文件和生成产物不提交到仓库。本仓库未为原创部分授予单独的开源许可证，第三方文件仍受各自文件头的再分发条款约束。
