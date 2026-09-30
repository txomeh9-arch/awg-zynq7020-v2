# 双通道任意波形发生器 V2

本工程面向 Smart ZYNQ SL V1.3B（XC7Z020）与 ACM9767 双通道 DAC。V2 目标是以 10/25/50 MSPS 生成 1 Hz～5 kHz 连续波形，并保留 AWG 单独输出 1 MHz 的测试能力；每路最多 1,048,576 个自定义样点。**确认后级设备的输入范围及极性前，只连接高阻示波器，不连接功放。**

工程包含 `rtl/` 波形及接口逻辑、`firmware/` Cortex-A9 裸机控制、`host/` 中文 Tkinter 程序、`constraints/` 引脚和时序约束、`sim/` 仿真、`tests/` 协议测试、`scripts/` 构建脚本和 `docs/` 接线与验收记录。逐针映射见 [接线表](docs/wiring.csv)，操作见 [快速开始](docs/quickstart.zh-CN.md)，通信格式见 [V2 协议](docs/protocol.zh-CN.md)，当前验证状态见 [构建与验收记录](docs/build_validation.zh-CN.md)，外部资料及移植代码见 [来源说明](THIRD_PARTY_NOTICES.md)。

所需环境：Vivado/Vitis 2026.1、Python 3.11+；上位机安装 `host/requirements.txt`。固件原生 C 单元测试还需要 `gcc` 在 `PATH` 中，或设置 `AWG_HOST_GCC` 为编译器路径。在 PowerShell 中从工程根目录运行：

```powershell
python -m pip install -r host/requirements.txt
python -m pytest -q -p no:cacheprovider tests
powershell -ExecutionPolicy Bypass -File sim/run.ps1
powershell -ExecutionPolicy Bypass -File sim/run_pl.ps1
powershell -ExecutionPolicy Bypass -File scripts/export_complete_xsa.ps1
powershell -ExecutionPolicy Bypass -File scripts/build_firmware.ps1
python host/gui.py
```

`build/`、`reports/` 是本地生成目录，不提交到仓库；XSA、位流和 ELF 只有在各自构建成功后才存在。`scripts/export_complete_xsa.ps1` 是生成带位流 XSA 的主构建命令；`scripts/build.ps1` 是独立的直接实现/报告流程，其 XSA 不含位流。将 Vivado/Vitis 的 `bin` 目录加入 `PATH`，或设置 `AWG_VIVADO_HOME` / `AWG_VITIS_HOME` 为安装根目录；许可证由工具常规环境变量管理，不写入工程。PS DDR 配置为单颗 MT41K256M16、16 位、512 MiB；裸机启动先测试保留的 8 MiB 样点区，失败时不启动网络或播放。双通道 FIFO 各 8192 点，DDR 模式在至少 4096 点预装后才允许启动。实际 50 MSPS 和网口持续吞吐需上板测量，脚本或仿真不能替代。

自定义波形逐点播放，频率为 `采样率 / (点数 × 整数分频)`。例如 10 MSPS 下，1,000,000 点、分频 1 只能得到 10 Hz；此长度不能直接得到 5 kHz。标准波形使用 48 位 DDS。CSV 只接受一列或两列、有限值且每个值在 `[-1,1]`。V2 电脑程序和第一版互不兼容。

模拟输出目标为高阻输入下 0.2～2 Vpp，目标误差为幅度 ≤2%、零点 ≤10 mV。这些是待实测的验收指标，不代表当前硬件已经达到。接线前核对板卡 V1.3B 丝印和两块板的 1 脚方向；杜邦线要短且固定，DAC 模块不能直接插在 J5 上。模拟输出到功放时使用短屏蔽线或同轴线。
