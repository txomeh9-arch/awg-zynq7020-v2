"""Chinese desktop console for the dual-channel AWG V2."""
from __future__ import annotations

import math
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, simpledialog, ttk

from calibration import (AmplifierProfile, ChannelCalibration, load_settings,
                         save_settings)
from protocol import (AWGDevice, SerialTransport, SocketTransport,
                      custom_divider, dds_word, read_csv)

ROOT = Path(__file__).resolve().parent
CONFIG_FILE = ROOT / "settings.json"
SHAPES = {"正弦": 0, "方波": 1, "三角波": 2, "锯齿波": 3}
SAMPLE_RATES = {"10 MSPS": 10_000_000, "25 MSPS": 25_000_000,
                "50 MSPS": 50_000_000}


class Application(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("双通道任意波形发生器 V2")
        self.geometry("1040x730")
        self.device: AWGDevice | None = None
        self.sample_rate = 10_000_000
        self.samples: list[list[int] | None] = [None, None]
        self.calibrations, self.profile = load_settings(CONFIG_FILE)
        self.display_cal = [item or ChannelCalibration(10 / 16383, -5, False)
                            for item in self.calibrations]
        self.busy = False
        self.status_text = tk.StringVar(value="未连接；未校准的电压仅用于 AWG 单独调试")
        self.profile_text = tk.StringVar(value=(
            f"功放配置：{self.profile.name}" if self.profile.verified else
            "功放型号与输入范围待核实：仅连接高阻示波器"))
        self.transport_text = tk.StringVar(value="网口")
        self.address_text = tk.StringVar(value="192.168.10.10")
        self.port_text = tk.StringVar()
        self.rate_text = tk.StringVar(value="10 MSPS")
        self.csv_text = tk.StringVar()
        self.single_channel = tk.StringVar(value="A")
        self.cycles_text = tk.StringVar(value="0")
        self.external = tk.BooleanVar(value=False)
        self.channel_vars: list[dict[str, tk.StringVar]] = []
        self._layout()
        self._ports()

    def _layout(self):
        top = ttk.LabelFrame(self, text="连接和采样率", padding=8)
        top.pack(fill="x", padx=8, pady=5)
        ttk.Combobox(top, textvariable=self.transport_text, values=["网口", "串口"],
                     width=7, state="readonly").pack(side="left")
        ttk.Label(top, text="板卡 IP").pack(side="left", padx=(12, 3))
        ttk.Entry(top, textvariable=self.address_text, width=17).pack(side="left")
        ttk.Label(top, text="串口").pack(side="left", padx=(12, 3))
        self.port_box = ttk.Combobox(top, textvariable=self.port_text, width=14)
        self.port_box.pack(side="left")
        ttk.Button(top, text="刷新", command=self._ports).pack(side="left", padx=4)
        ttk.Button(top, text="连接", command=lambda: self._job(self._connect)).pack(side="left", padx=4)
        ttk.Label(top, text="采样率").pack(side="left", padx=(14, 3))
        ttk.Combobox(top, textvariable=self.rate_text, values=list(SAMPLE_RATES),
                     width=11, state="readonly").pack(side="left")
        ttk.Button(top, text="设置", command=lambda: self._job(self._set_rate)).pack(side="left")

        for channel in ("A", "B"):
            panel = ttk.LabelFrame(self, text=f"通道 {channel}", padding=8)
            panel.pack(fill="x", padx=8, pady=4)
            vars = {"mode": tk.StringVar(value="标准波形"),
                    "shape": tk.StringVar(value="正弦"),
                    "freq": tk.StringVar(value="1000"),
                    "vpp": tk.StringVar(value="2"),
                    "offset": tk.StringVar(value="0"),
                    "phase": tk.StringVar(value="0"),
                    "actual": tk.StringVar(value="实际频率：—")}
            self.channel_vars.append(vars)
            fields = [("模式", "mode", ["标准波形", "CSV"]),
                      ("波形", "shape", list(SHAPES)),
                      ("重复频率 Hz", "freq", None),
                      ("幅度 Vpp", "vpp", None),
                      ("偏置 V", "offset", None),
                      ("初相位 °", "phase", None)]
            for column, (label, key, options) in enumerate(fields):
                ttk.Label(panel, text=label).grid(row=0, column=column, padx=4, sticky="w")
                widget = (ttk.Combobox(panel, textvariable=vars[key], values=options,
                                       width=12, state="readonly") if options else
                          ttk.Entry(panel, textvariable=vars[key], width=13))
                widget.grid(row=1, column=column, padx=4, pady=3)
            ttk.Label(panel, textvariable=vars["actual"]).grid(row=1, column=6, padx=10)
            for key in ("freq", "mode"):
                vars[key].trace_add("write", lambda *_args: self._actuals())

        csv_box = ttk.LabelFrame(self, text="自定义波形", padding=8)
        csv_box.pack(fill="x", padx=8, pady=4)
        ttk.Entry(csv_box, textvariable=self.csv_text).pack(side="left", fill="x", expand=True)
        ttk.Button(csv_box, text="导入并预览", command=self._load_csv).pack(side="left", padx=5)
        ttk.Label(csv_box, text="单列目标").pack(side="left")
        ttk.Combobox(csv_box, textvariable=self.single_channel, values=["A", "B"],
                     width=3, state="readonly").pack(side="left")
        ttk.Button(csv_box, text="上传并提交", command=lambda: self._job(self._upload)).pack(side="left", padx=6)
        self.canvas = tk.Canvas(self, background="white", height=240,
                                highlightbackground="#aaa", highlightthickness=1)
        self.canvas.pack(fill="both", expand=True, padx=8, pady=5)
        self.canvas.bind("<Configure>", lambda _e: self._preview())

        actions = ttk.Frame(self, padding=8)
        actions.pack(fill="x")
        ttk.Button(actions, text="应用参数", command=lambda: self._job(self._apply)).pack(side="left", padx=3)
        ttk.Label(actions, text="周期数 (0=连续)").pack(side="left", padx=(15, 3))
        ttk.Entry(actions, textvariable=self.cycles_text, width=8).pack(side="left")
        ttk.Checkbutton(actions, text="外部触发", variable=self.external).pack(side="left", padx=9)
        ttk.Button(actions, text="双通道布防", command=lambda: self._job(self._arm)).pack(side="left", padx=3)
        ttk.Button(actions, text="同步启动", command=lambda: self._job(self._start)).pack(side="left", padx=3)
        ttk.Button(actions, text="停止", command=lambda: self._job(self._stop)).pack(side="left", padx=3)
        ttk.Button(actions, text="状态", command=lambda: self._job(self._status)).pack(side="left", padx=3)
        ttk.Button(actions, text="清故障", command=lambda: self._job(self._clear)).pack(side="left", padx=3)

        bottom = ttk.Frame(self, padding=8)
        bottom.pack(fill="x")
        ttk.Button(bottom, text="功放输入范围配置", command=self._profile_dialog).pack(side="left")
        ttk.Button(bottom, text="录入双通道校准测量值", command=self._calibration_dialog).pack(side="left", padx=8)
        ttk.Label(bottom, textvariable=self.profile_text).pack(side="left", padx=10)
        ttk.Label(self, textvariable=self.status_text, padding=8).pack(fill="x")
        self._actuals()

    def _ports(self):
        try:
            from serial.tools import list_ports
            ports = [item.device for item in list_ports.comports()]
            self.port_box["values"] = ports
            if ports and not self.port_text.get():
                self.port_text.set(ports[0])
        except ImportError:
            self.port_box["values"] = []

    def _job(self, fn):
        if self.busy:
            return
        self.busy = True

        def worker():
            try:
                message = fn()
                self.after(0, lambda: self.status_text.set(message or "操作完成"))
            except Exception as exc:
                detail = str(exc)
                self.after(0, lambda: messagebox.showerror("操作失败", detail))
                self.after(0, lambda: self.status_text.set(detail))
            finally:
                self.after(0, lambda: setattr(self, "busy", False))

        threading.Thread(target=worker, daemon=True).start()

    def _require(self) -> AWGDevice:
        if not self.device:
            raise RuntimeError("请先连接设备")
        return self.device

    def _connect(self):
        if self.device:
            self.device.transport.close()
        transport = (SocketTransport(self.address_text.get())
                     if self.transport_text.get() == "网口"
                     else SerialTransport(self.port_text.get()))
        device = AWGDevice(transport)
        version, channels, rate, max_points = device.info()
        if version != 2 or channels != 2:
            transport.close()
            raise RuntimeError("设备不是双通道 V2 协议")
        self.device = device
        self.sample_rate = rate
        for text, value in SAMPLE_RATES.items():
            if value == rate:
                self.after(0, lambda text=text: self.rate_text.set(text))
        return f"已连接：{rate / 1e6:g} MSPS，每路最多 {max_points} 点"

    def _set_rate(self):
        rate = SAMPLE_RATES[self.rate_text.get()]
        device = self._require()
        device.stop(3)
        device.set_rate(rate)
        self.sample_rate = rate
        self.after(0, self._actuals)
        return f"采样率已设置为 {rate / 1e6:g} MSPS；输出保持停止，需重新布防启动"

    def _actuals(self):
        for index, item in enumerate(self.channel_vars):
            try:
                hz = float(item["freq"].get())
                if item["mode"].get() == "CSV":
                    samples = self.samples[index]
                    if samples is None:
                        raise ValueError("未加载 CSV")
                    _divider, actual = custom_divider(hz, len(samples), self.sample_rate)
                else:
                    _word, actual = dds_word(hz, self.sample_rate)
                item["actual"].set(f"实际频率：{actual:.9g} Hz")
            except (ValueError, TypeError):
                item["actual"].set("实际频率：不可实现")

    def _load_csv(self):
        path = filedialog.askopenfilename(filetypes=[("CSV", "*.csv"), ("所有文件", "*.*")])
        if not path:
            return
        try:
            a, b = read_csv(path)
            self.samples = [a, b] if b is not None else ([a, self.samples[1]]
                                                            if self.single_channel.get() == "A"
                                                            else [self.samples[0], a])
            self.csv_text.set(path)
            self._preview()
            self._actuals()
            self.status_text.set(f"已读取 {len(a)} 点" + ("，双通道" if b else "，单通道"))
        except Exception as exc:
            messagebox.showerror("CSV 错误", str(exc))

    def _preview(self):
        canvas = self.canvas
        canvas.delete("all")
        width, height = max(2, canvas.winfo_width()), max(2, canvas.winfo_height())
        canvas.create_line(0, height / 2, width, height / 2, fill="#ccc")
        for index, color in enumerate(("#1274c8", "#d45a1d")):
            samples = self.samples[index]
            if not samples:
                continue
            points = []
            for pixel in range(width):
                position = min(len(samples) - 1, pixel * len(samples) // width)
                points.extend((pixel, height * (1 - samples[position] / 16383)))
            canvas.create_line(*points, fill=color, width=2)
            canvas.create_text(12, 15 + 20 * index, text="AB"[index], fill=color, anchor="w")

    def _config_channel(self, device: AWGDevice, index: int) -> str:
        values = self.channel_vars[index]
        hz = float(values["freq"].get())
        vpp = float(values["vpp"].get())
        offset = float(values["offset"].get())
        phase = float(values["phase"].get())
        self.profile.validate(vpp, offset, hz)
        calibration = self.display_cal[index]
        gain, offset_code = calibration.settings(vpp, offset,
                                                 self.profile.input_min,
                                                 self.profile.input_max)
        idle_code = round(calibration.code(self.profile.idle_voltage))
        if not 0 <= idle_code <= 16383:
            raise ValueError("功放空闲电压超出 DAC 可输出范围")
        arbitrary = values["mode"].get() == "CSV"
        divider = 1
        if arbitrary:
            samples = self.samples[index]
            if samples is None:
                raise ValueError(f"通道 {'AB'[index]} 尚未加载 CSV")
            divider, actual = custom_divider(hz, len(samples), self.sample_rate)
        else:
            _word, actual = dds_word(hz, self.sample_rate)
        device.configure(index + 1, arbitrary=arbitrary, shape=SHAPES[values["shape"].get()],
                         frequency=hz if not arbitrary else 0, phase_degrees=phase,
                         gain=gain, offset=offset_code, divider=divider,
                         sample_rate=self.sample_rate, idle_code=idle_code)
        return f"{'AB'[index]}={actual:.9g} Hz"

    def _apply(self):
        device = self._require()
        info = [self._config_channel(device, index) for index in (0, 1)]
        device.apply(3)
        warning = "；电压为未校准估算" if not all(x.measured for x in self.display_cal) else ""
        return "参数已应用：" + "，".join(info) + warning

    def _upload(self):
        device = self._require()
        if not self.csv_text.get():
            raise ValueError("请先选择 CSV 文件")
        a, b = read_csv(self.csv_text.get())
        channels = [(1, a), (2, b)] if b is not None else [(1 if self.single_channel.get() == "A" else 2, a)]
        for channel, values in channels:
            def progress(done, total, channel=channel):
                self.after(0, lambda: self.status_text.set(
                    f"通道 {'AB'[channel - 1]} 上传 {done}/{total}"))
            device.upload(channel, values, progress)
        mask = sum(1 << (channel - 1) for channel, _ in channels)
        device.commit(mask)
        return f"波形 CRC 校验及提交完成；通道掩码 {mask}"

    def _arm(self):
        cycles = int(self.cycles_text.get())
        self._require().arm(3, cycles, self.external.get())
        return "已布防外部触发" if self.external.get() else "已布防，等待同步启动"

    def _start(self):
        self._require().start(3)
        return "两路已同步启动"

    def _stop(self):
        self._require().stop(3)
        return "已停止并回到空闲码"

    def _status(self):
        run, faults, under_a, under_b = self._require().status()
        return f"运行掩码 {run}；故障 {faults}；欠载 A={under_a} B={under_b}"

    def _clear(self):
        self._require().clear_fault()
        return "故障标志已清除"

    def _calibration_dialog(self):
        for index in (0, 1):
            content = simpledialog.askstring("录入校准", f"通道 {'AB'[index]}：输入至少三个码值和示波器电压，\n"
                                           "每行格式 码值,电压；推荐 0、8192、16383。")
            if content is None:
                return
            try:
                points = []
                for line in content.splitlines():
                    code, voltage = line.split(",")
                    points.append((int(code.strip()), float(voltage.strip())))
                self.calibrations[index] = ChannelCalibration.from_points(points)
                self.display_cal[index] = self.calibrations[index]
            except Exception as exc:
                messagebox.showerror("校准数据错误", str(exc))
                return
        save_settings(CONFIG_FILE, self.calibrations, self.profile)
        self.status_text.set("双通道校准已保存；请以高阻示波器再次核对波形幅度与零点")

    def _profile_dialog(self):
        current = self.profile
        fields = [("完整型号", current.name), ("输入下限 V（未知留空）", current.input_min),
                  ("输入上限 V（未知留空）", current.input_max),
                  ("频率上限 Hz（未知留空）", current.max_frequency_hz),
                  ("空闲电压 V", current.idle_voltage)]
        results = []
        for label, initial in fields:
            result = simpledialog.askstring("功放输入配置", label,
                                            initialvalue="" if initial is None else str(initial))
            if result is None:
                return
            results.append(result.strip())
        try:
            def optional(value):
                return float(value) if value else None
            profile = AmplifierProfile(results[0] or "未指定功放（待核实输入范围）",
                                       optional(results[1]), optional(results[2]),
                                       optional(results[3]), float(results[4]),
                                       False)
            if profile.input_min is not None and profile.input_max is not None \
                    and profile.input_min >= profile.input_max:
                raise ValueError("输入下限必须小于上限")
            if all(results[:4]):
                profile.verified = messagebox.askyesno(
                    "核实功放规格", "已从该完整子型号的资料核对输入下限、上限和频率上限吗？")
            self.profile = profile
            self.profile_text.set(f"功放配置：{profile.name}" if profile.verified else
                                  "功放型号与输入范围待核实：仅连接高阻示波器")
            save_settings(CONFIG_FILE, self.calibrations, profile)
            self.status_text.set("已保存功放输入配置" if profile.verified else "功放子型号或输入范围仍待核实")
        except Exception as exc:
            messagebox.showerror("配置错误", str(exc))


if __name__ == "__main__":
    Application().mainloop()
