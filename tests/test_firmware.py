"""Compile the actual C command processor with a hardware stub and drive it via Python host."""
import ctypes
import os
import shutil
import subprocess
import sys
import zlib
import struct
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from host.protocol import AWGDevice, BEGIN, DATA, END, COMMIT, QUERY_UPLOAD, encode_frame

GCC = Path(os.environ["AWG_HOST_GCC"]) if os.environ.get("AWG_HOST_GCC") else (
    Path(shutil.which("gcc") or "gcc-not-found"))


class CTransport:
    def __init__(self, dll, state=None, session=2):
        self.dll = dll
        self.state = state if state is not None else ctypes.create_string_buffer(65536)
        self.session = session
        if state is None:
            dll.awg_device_init(ctypes.byref(self.state))
        self.reply = b""

    def write(self, frame):
        inp = ctypes.create_string_buffer(frame)
        output = ctypes.create_string_buffer(32788)
        count = self.dll.awg_device_process(ctypes.byref(self.state), self.session,
                                            inp, len(frame), output, len(output))
        self.reply = output.raw[:count]

    def read(self, count):
        if not self.reply:
            raise TimeoutError
        data, self.reply = self.reply[:count], self.reply[count:]
        return data


@pytest.fixture(scope="module")
def c_device():
    library = ROOT / "build" / "awg_device_test.dll"
    if not GCC.exists():
        pytest.skip("Bundled MinGW GCC is unavailable")
    subprocess.run([str(GCC), "-std=c11", "-O2", "-shared",
                    "-I", str(ROOT / "firmware"), "-I", str(ROOT / "tests" / "c_stubs"),
                    str(ROOT / "firmware" / "awg_device.c"),
                    str(ROOT / "tests" / "c_stubs" / "hw_stub.c"),
                    "-o", str(library)], check=True)
    dll = ctypes.CDLL(str(library))
    dll.awg_device_process.restype = ctypes.c_size_t
    dll.awg_device_process.argtypes = [ctypes.c_void_p, ctypes.c_size_t,
                                        ctypes.c_void_p, ctypes.c_size_t,
                                        ctypes.c_void_p, ctypes.c_size_t]
    dll.stub_bram.restype = ctypes.c_uint16
    dll.stub_bram.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_uint]
    dll.stub_status.restype = ctypes.c_uint32
    dll.stub_set_status.argtypes = [ctypes.c_uint32]
    dll.stub_command_count.restype = ctypes.c_uint32
    dll.stub_wave.restype = ctypes.c_uint16
    dll.stub_wave.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_uint]
    return dll


def test_c_protocol_upload_commit_and_resume(c_device):
    transport = CTransport(c_device)
    client = AWGDevice(transport)
    assert client.info() == (2, 2, 10_000_000, 1_048_576)
    client.upload(1, [0, 8192, 16383])
    client.upload(2, [7, 8])
    client.commit(3)
    assert [c_device.stub_bram(0, 1, i) for i in range(3)] == [0, 8192, 16383]
    assert [c_device.stub_bram(1, 1, i) for i in range(2)] == [7, 8]
    second = struct.pack("<3H", 2, 3, 4)
    token, offset = struct.unpack("<II", client.request(
        BEGIN, struct.pack("<BII", 1, 3, zlib.crc32(second))))
    assert offset == 0
    client.request(DATA, struct.pack("<IIH", token, 0, 2))
    assert struct.unpack("<I", client.request(QUERY_UPLOAD, struct.pack("<I", token)))[0] == 1
    with pytest.raises(RuntimeError):
        client.commit(1)
    client.upload(1, [2, 3, 4])
    client.commit(1)
    assert [c_device.stub_bram(0, 0, i) for i in range(3)] == [2, 3, 4]


def test_c_finite_playback_locks_parameters_and_continuous_change(c_device):
    client = AWGDevice(CTransport(c_device))
    for channel in (1, 2):
        client.configure(channel, arbitrary=False, shape=0, frequency=1000,
                         phase_degrees=0, gain=32768, offset=0, divider=1,
                         sample_rate=10_000_000)
    client.apply(3)
    client.arm(3, cycles=2)
    client.start(3)
    assert c_device.stub_status() & 0x6 == 0x6
    with pytest.raises(RuntimeError, match="状态"):
        client.configure(1, arbitrary=False, shape=0, frequency=2000,
                         phase_degrees=0, gain=32768, offset=0, divider=1,
                         sample_rate=10_000_000)
    client.stop(3)
    client.arm(3)
    client.start(3)
    client.configure(1, arbitrary=False, shape=1, frequency=2000,
                     phase_degrees=0, gain=16384, offset=0, divider=1,
                     sample_rate=10_000_000)
    client.apply(1)
    assert c_device.stub_status() & 0x2


def test_c_full_million_point_upload(c_device):
    client = AWGDevice(CTransport(c_device))
    client.stop(3)
    data = [index & 16383 for index in range(1_048_576)]
    client.upload(1, data)
    client.commit(1)
    assert c_device.stub_wave(0, 1, 0) == 0
    assert c_device.stub_wave(0, 1, 12345) == 12345
    assert c_device.stub_wave(0, 1, 1_048_575) == 16383


def test_c_external_arm_does_not_accept_software_start(c_device):
    client = AWGDevice(CTransport(c_device))
    client.stop(3)
    client.arm(1, external=True)
    with pytest.raises(RuntimeError, match="状态"):
        client.start(1)


def test_c_bad_crc_and_duplicate_request_preserve_active_wave(c_device):
    transport = CTransport(c_device)
    client = AWGDevice(transport)
    client.upload(1, [11, 22, 33])
    client.commit(1)
    payload = struct.pack("<BII", 1, 3, zlib.crc32(struct.pack("<3H", 9, 8, 7)))
    frame = encode_frame(BEGIN, 401, payload)
    bad_frame = frame[:-1] + bytes([frame[-1] ^ 1])
    transport.write(bad_frame)
    assert transport.reply == b""
    assert [c_device.stub_bram(0, 1, i) for i in range(3)] == [11, 22, 33]
    transport.write(frame)
    reply = transport.reply
    transport.write(frame)
    assert transport.reply == reply
    assert [c_device.stub_bram(0, 1, i) for i in range(3)] == [11, 22, 33]


def test_c_complete_upload_crc_failure_can_restart_same_wave(c_device):
    client = AWGDevice(CTransport(c_device))
    client.upload(1, [11, 22, 33])
    client.commit(1)
    good = struct.pack("<3H", 4, 5, 6)
    metadata = struct.pack("<BII", 1, 3, zlib.crc32(good))
    token, offset = struct.unpack("<II", client.request(BEGIN, metadata))
    assert offset == 0
    client.request(DATA, struct.pack("<II", token, 0) + struct.pack("<3H", 4, 5, 7))
    with pytest.raises(RuntimeError, match="CRC"):
        client.request(END, struct.pack("<I", token))
    assert [c_device.stub_bram(0, 1, i) for i in range(3)] == [11, 22, 33]
    retry_token, retry_offset = struct.unpack("<II", client.request(BEGIN, metadata))
    assert retry_token != token and retry_offset == 0
    client.upload(1, [4, 5, 6])
    client.commit(1)
    assert [c_device.stub_bram(0, 0, i) for i in range(3)] == [4, 5, 6]


def test_c_clock_loss_latches_fault_without_command_timeout(c_device):
    client = AWGDevice(CTransport(c_device))
    before = c_device.stub_command_count()
    c_device.stub_set_status(0)
    try:
        _, fault, _, _ = client.status()
        assert fault & 4
        assert c_device.stub_command_count() == before
    finally:
        c_device.stub_set_status(1 << 11)


def test_c_control_owner_and_universal_stop(c_device):
    first = CTransport(c_device, session=2)
    second = CTransport(c_device, state=first.state, session=3)
    a, b = AWGDevice(first), AWGDevice(second)
    a.configure(1, arbitrary=False, shape=0, frequency=1000,
                phase_degrees=0, gain=32768, offset=0, divider=1,
                sample_rate=10_000_000)
    with pytest.raises(RuntimeError):
        b.set_rate(25_000_000)
    b.stop(3)


def test_hardware_driver_compiles_against_mmio_contract():
    if not GCC.exists():
        pytest.skip("Bundled MinGW GCC is unavailable")
    subprocess.run([str(GCC), "-std=c11", "-Wall", "-Wextra", "-Werror",
                    "-fsyntax-only", "-I", str(ROOT / "firmware"),
                    "-I", str(ROOT / "tests" / "c_stubs"),
                    str(ROOT / "firmware" / "awg_hw.c")], check=True)
