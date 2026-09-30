import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "host"))
from calibration import AmplifierProfile, ChannelCalibration, load_settings, save_settings


def test_three_point_calibration_and_voltage_limits():
    calibration = ChannelCalibration.from_points([(0, -5), (8192, 0), (16383, 5)])
    gain, offset = calibration.settings(2, 0, -5, 5)
    assert gain == pytest.approx(6554, abs=2)
    assert offset == pytest.approx(0, abs=1)
    with pytest.raises(ValueError):
        calibration.settings(2, 0, 0, 10)
    with pytest.raises(ValueError):
        calibration.settings(12, 0)
    path = Path(__file__).resolve().parents[1] / "build" / "test-settings.json"
    profile = AmplifierProfile("test amplifier", 0, 5, 5000, 0, True)
    save_settings(path, [calibration, calibration], profile)
    restored, restored_profile = load_settings(path)
    assert restored[0].measured and restored_profile.input_max == 5
    with pytest.raises(ValueError):
        restored_profile.validate(2, 0, 1000)
    restored_profile.validate(2, 1, 1000)
