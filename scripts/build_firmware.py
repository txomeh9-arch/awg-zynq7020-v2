"""Run through build_firmware.ps1 with a Vitis 2026.1 installation."""
from pathlib import Path
import os
import vitis
from check_hwh import validate_xsa

root = Path(__file__).resolve().parents[1]
xsa = root / "build" / "awg_v2_complete.xsa"
if not xsa.exists():
    raise FileNotFoundError(f"先运行 scripts/export_complete_xsa.ps1 生成 {xsa}")
validate_xsa(xsa)

client = vitis.create_client()
client.set_workspace((root / "build" / "vitis").as_posix())
sdt_repo = Path(os.environ["AWG_SDT_REPO"]) if os.environ.get("AWG_SDT_REPO") else (
    Path(os.environ["AWG_VITIS_HOME"]).resolve().parent / "data" / "system-device-tree-xlnx")
if not sdt_repo.is_dir():
    raise FileNotFoundError(f"缺少系统设备树仓库：{sdt_repo}；可设置 AWG_SDT_REPO")
platform = client.create_platform_component(
    name="awg_platform", hw_design=xsa.as_posix(),
    domain_name="standalone_ps7", cpu="ps7_cortexa9_0", os="standalone",
    advanced_options=client.create_advanced_options_dict(sdt_repo=sdt_repo.as_posix()))
domain = platform.get_domain("standalone_ps7")
domain.set_lib("lwip220")
platform.build()
platform_path = client.find_platform_in_repos("awg_platform")
app = client.create_app_component(name="awg_firmware", platform=platform_path,
                                  domain="standalone_ps7")
source_names = ["awg_hw.h", "awg_hw.c", "awg_device.h", "awg_device.c",
                "main.c", "platform.c", "platform_zynq.c", "platform.h",
                "platform_config.h"]
app.import_files(from_loc=(root / "firmware").as_posix(), files=source_names,
                 dest_dir_in_cmp="src")
app.build()
vitis.dispose()
print("AWG_V2_FIRMWARE_BUILD_COMPLETE")
