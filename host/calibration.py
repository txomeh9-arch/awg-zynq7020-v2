"""Per-channel voltage conversion and configurable amplifier input limits."""
from __future__ import annotations

import json
import math
from dataclasses import dataclass
from pathlib import Path


@dataclass
class ChannelCalibration:
    # Measured voltage = slope * DAC code + intercept at a high-Z input.
    slope: float
    intercept: float
    measured: bool = False

    @classmethod
    def from_points(cls, points: list[tuple[int, float]]) -> "ChannelCalibration":
        if len(points) < 3 or any(not 0 <= code <= 16383 or not math.isfinite(voltage)
                                  for code, voltage in points):
            raise ValueError("每路至少测量三个有效 DAC 码值及电压")
        n = len(points)
        sx = sum(x for x, _ in points)
        sy = sum(y for _, y in points)
        sxx = sum(x * x for x, _ in points)
        sxy = sum(x * y for x, y in points)
        denominator = n * sxx - sx * sx
        if denominator == 0:
            raise ValueError("测量码值不能全部相同")
        slope = (n * sxy - sx * sy) / denominator
        if slope <= 0:
            raise ValueError("测量电压应随 DAC 码值上升")
        return cls(slope, (sy - slope * sx) / n, True)

    def voltage(self, code: float) -> float:
        return self.slope * code + self.intercept

    def code(self, voltage: float) -> float:
        if not math.isfinite(voltage) or self.slope <= 0:
            raise ValueError("校准系数或电压无效")
        return (voltage - self.intercept) / self.slope

    def settings(self, vpp: float, offset_v: float,
                 input_min: float | None = None,
                 input_max: float | None = None) -> tuple[int, int]:
        if not math.isfinite(vpp) or not math.isfinite(offset_v) or vpp < 0:
            raise ValueError("Vpp 与偏置必须为有限数，且 Vpp 不得为负")
        low, high = offset_v - vpp / 2, offset_v + vpp / 2
        if input_min is not None and low < input_min - 1e-9:
            raise ValueError("负峰值低于功放允许输入")
        if input_max is not None and high > input_max + 1e-9:
            raise ValueError("正峰值高于功放允许输入")
        if self.code(low) < 0 or self.code(high) > 16383:
            raise ValueError("波形电压超出已校准的 DAC 模块范围")
        # RTL evaluates: round((raw-8192)*gain/32768)+8192+offset.
        full_span = self.voltage(16383) - self.voltage(0)
        gain = round(vpp / full_span * 32768)
        midpoint_code = self.code(offset_v)
        offset_code = round(midpoint_code - 8192)
        if not 0 <= gain <= 32768 or not -8192 <= offset_code <= 8191:
            raise ValueError("增益或偏置码超出 FPGA 范围")
        # Rounding can push a peak outside the requested voltage envelope.
        for raw in (0, 16383):
            code = max(0, min(16383, ((raw - 8192) * gain >> 15) + 8192 + offset_code))
            value = self.voltage(code)
            if input_min is not None and value < input_min - abs(self.slope):
                raise ValueError("量化后的负峰值超出功放输入范围")
            if input_max is not None and value > input_max + abs(self.slope):
                raise ValueError("量化后的正峰值超出功放输入范围")
        return gain, offset_code


@dataclass
class AmplifierProfile:
    name: str = "未指定功放（待核实输入范围）"
    input_min: float | None = None
    input_max: float | None = None
    max_frequency_hz: float | None = None
    idle_voltage: float = 0.0
    verified: bool = False

    def validate(self, vpp: float, offset: float, frequency: float) -> None:
        if not math.isfinite(frequency) or frequency < 0:
            raise ValueError("频率无效")
        if self.max_frequency_hz is not None and frequency > self.max_frequency_hz:
            raise ValueError("频率超过已配置的功放上限")
        if self.input_min is not None and offset - vpp / 2 < self.input_min:
            raise ValueError("波形低于功放输入下限")
        if self.input_max is not None and offset + vpp / 2 > self.input_max:
            raise ValueError("波形高于功放输入上限")


def load_settings(path: str | Path) -> tuple[list[ChannelCalibration | None], AmplifierProfile]:
    config = Path(path)
    if not config.exists():
        return [None, None], AmplifierProfile()
    data = json.loads(config.read_text(encoding="utf-8"))
    calibration = [ChannelCalibration(**entry) if entry else None
                   for entry in data["channels"]]
    if len(calibration) != 2:
        raise ValueError("校准文件必须包含两路")
    return calibration, AmplifierProfile(**data["amplifier"])


def save_settings(path: str | Path, channels: list[ChannelCalibration | None],
                  amplifier: AmplifierProfile) -> None:
    from dataclasses import asdict
    if len(channels) != 2:
        raise ValueError("需要两路校准数据")
    payload = {"channels": [asdict(x) if x else None for x in channels],
               "amplifier": asdict(amplifier)}
    Path(path).write_text(json.dumps(payload, indent=2, ensure_ascii=False) + "\n",
                          encoding="utf-8")
