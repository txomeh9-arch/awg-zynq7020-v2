"""Validate the Vivado hardware handoff against the firmware's MMIO map."""
from __future__ import annotations

import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile


EXPECTED_BASES = {
    "dma_a": 0x40400000,
    "dma_b": 0x40410000,
    "gpio_command": 0x41200000,
    "gpio_status": 0x41210000,
}


def validate_xsa(path: Path) -> None:
    with ZipFile(path) as archive:
        names = set(archive.namelist())
        if "awg_system.hwh" not in names or "ps7_init.tcl" not in names or not any(
            name.endswith(".bit") for name in names
        ):
            raise ValueError("XSA 缺少硬件交接、PS 初始化或位流")
        root = ET.fromstring(archive.read("awg_system.hwh"))
    modules = {module.get("INSTANCE"): module for module in root.iter("MODULE")}
    for name, expected in EXPECTED_BASES.items():
        module = modules.get(name)
        if module is None:
            raise ValueError(f"XSA 缺少 {name}")
        parameter = next((item for item in module.iter("PARAMETER")
                          if item.get("NAME") == "C_BASEADDR"), None)
        actual = int(parameter.get("VALUE"), 0) if parameter is not None else None
        if actual != expected:
            raise ValueError(f"{name} 地址不符：XSA={actual!r}，固件=0x{expected:08x}")
    ddr_ranges = [item for item in root.iter("MEMRANGE")
                  if item.get("INSTANCE") == "ps7" and
                  "DDR" in item.get("ADDRESSBLOCK", "")]
    if not any(int(item.get("HIGHVALUE", "0"), 0) >= 0x1FFFFFFF
               for item in ddr_ranges):
        raise ValueError("XSA 的 DDR 地址窗口不足 512 MiB")


if __name__ == "__main__":
    xsa_path = Path(sys.argv[1]) if len(sys.argv) > 1 else (
        Path(__file__).resolve().parents[1] / "build" / "awg_v2_complete.xsa")
    validate_xsa(xsa_path)
    print("AWG_V2_XSA_MMIO_OK")
