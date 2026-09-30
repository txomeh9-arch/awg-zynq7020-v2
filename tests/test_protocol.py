import sys
import struct
import zlib
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host.protocol import (AWGDevice, BEGIN, COMMIT, DATA, END, QUERY_UPLOAD,
                           decode_frame, dds_word, custom_divider, encode_frame,
                           normalized_to_codes, read_csv)
from sim.device_model import DeviceModel


class Transport:
    def __init__(self, device, session="default"):
        self.device = device
        self.session = session
        self.reply = b""
        self.drop_once = False

    def write(self, packet):
        result = self.device.process(packet, self.session)
        if self.drop_once:
            self.drop_once = False
            self.reply = b""
        else:
            self.reply = result

    def read(self, length):
        if not self.reply:
            raise TimeoutError
        result, self.reply = self.reply[:length], self.reply[length:]
        return result


def test_frame_crc_and_limits():
    frame = encode_frame(0x01, 0x12345678, b"abc")
    assert decode_frame(frame) == (0x01, 0x12345678, 0, b"abc")
    with pytest.raises(ValueError):
        decode_frame(frame[:-1] + b"z")
    with pytest.raises(ValueError):
        decode_frame(frame[:-1])
    with pytest.raises(ValueError):
        encode_frame(1, 1, b"0" * 32769)


def test_wave_math_and_csv():
    assert dds_word(1, 50_000_000)[1] == pytest.approx(1, abs=0.000001)
    with pytest.raises(ValueError):
        custom_divider(2_000_000, 51, 50_000_000)
    assert normalized_to_codes([-1, 0, 1]) == [0, 8192, 16383]
    fixture_root = Path(__file__).resolve().parent
    a, b = read_csv(fixture_root / "two_columns.csv")
    assert a == [0, 8192, 16383] and b == [16383, 8192, 0]
    with pytest.raises(ValueError):
        read_csv(fixture_root / "nan.csv")


def test_upload_retries_and_active_wave_survives_interruption():
    model = DeviceModel()
    transport = Transport(model)
    client = AWGDevice(transport)
    assert client.info() == (2, 2, 10_000_000, 1_048_576)
    first = [0, 100, 8192, 16383]
    transport.drop_once = True
    client.upload(1, first)
    client.commit(1)
    assert model.active_wave[0] == struct.pack("<4H", *first)
    second = [7, 8, 9]
    token, offset = struct.unpack("<II", client.request(
        BEGIN, struct.pack("<BII", 1, 3, zlib.crc32(struct.pack("<3H", *second)))))
    assert offset == 0
    client.request(DATA, struct.pack("<IIH", token, 0, second[0]))
    assert struct.unpack("<I", client.request(QUERY_UPLOAD, struct.pack("<I", token)))[0] == 1
    with pytest.raises(RuntimeError):
        client.commit(1)
    assert model.active_wave[0] == struct.pack("<4H", *first)
    client.upload(1, second)
    client.commit(1)
    assert model.active_wave[0] == struct.pack("<3H", *second)


def test_atomic_dual_commit_and_bad_sample():
    model = DeviceModel()
    client = AWGDevice(Transport(model))
    client.upload(1, [1, 2, 3])
    with pytest.raises(RuntimeError):
        client.commit(3)
    assert model.active_wave == [None, None]
    client.upload(2, [4, 5])
    client.commit(3)
    assert model.active_wave[0] == struct.pack("<3H", 1, 2, 3)
    assert model.active_wave[1] == struct.pack("<2H", 4, 5)
    with pytest.raises(ValueError):
        client.upload(1, [16384])


def test_frequency_and_control_interlock():
    model = DeviceModel()
    a = AWGDevice(Transport(model, "a"))
    b = AWGDevice(Transport(model, "b"))
    a.configure(1, arbitrary=False, shape=0, frequency=1000, phase_degrees=30,
                gain=32768, offset=0, divider=1, sample_rate=10_000_000)
    a.apply(1)
    a.arm(1)
    a.start(1)
    assert model.run_mask == 1
    with pytest.raises(RuntimeError):
        b.set_rate(25_000_000)
    a.set_rate(25_000_000)
    assert model.run_mask == 0
    assert model.sample_rate == 25_000_000
