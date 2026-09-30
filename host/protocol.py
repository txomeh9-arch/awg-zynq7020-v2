"""AWG V2 framing and waveform conversion; shared by TCP and serial transports.

Wire format: 20-byte little-endian header <4sBBHIII> followed by payload.
CRC-32/ISO-HDLC covers the first 16 header bytes and the payload.  The status
field is zero in requests. Responses set bit 7 of the operation code.
"""
from __future__ import annotations

import csv
import math
import socket
import struct
import threading
import zlib
from array import array
from pathlib import Path
import sys

MAGIC = b"AWG2"
HEADER = struct.Struct("<4sBBHIII")
MAX_PAYLOAD = 32768
MAX_POINTS = 1_048_576
PHASE_MOD = 1 << 48

INFO, STATUS, CONFIG, APPLY, RATE = 0x01, 0x02, 0x03, 0x04, 0x05
BEGIN, DATA, END, COMMIT, QUERY_UPLOAD = 0x10, 0x11, 0x12, 0x13, 0x14
ARM, START, STOP, CLEAR_FAULT = 0x20, 0x21, 0x22, 0x23

ERRORS = {
    1: "CRC 校验失败", 2: "帧或参数长度错误", 3: "参数超出范围",
    4: "当前状态不允许此操作", 5: "上传序号或偏移错误",
    6: "正在由另一连接修改参数", 7: "硬件故障", 8: "不支持的命令",
}


def encode_frame(op: int, request_id: int, payload: bytes = b"", *,
                 status: int = 0, flags: int = 0) -> bytes:
    if not 0 <= op <= 255 or not 0 <= request_id <= 0xFFFFFFFF:
        raise ValueError("无效操作码或请求序号")
    if len(payload) > MAX_PAYLOAD:
        raise ValueError("帧负载超过 32768 字节")
    prefix = struct.pack("<4sBBHII", MAGIC, op, flags, status, request_id, len(payload))
    return prefix + struct.pack("<I", zlib.crc32(prefix + payload)) + payload


def decode_frame(frame: bytes) -> tuple[int, int, int, bytes]:
    if len(frame) < HEADER.size:
        raise ValueError("帧头不完整")
    magic, op, _flags, status, request_id, length, crc = HEADER.unpack_from(frame)
    if magic != MAGIC or length > MAX_PAYLOAD or len(frame) != HEADER.size + length:
        raise ValueError("帧头或负载长度无效")
    payload = frame[HEADER.size:]
    if zlib.crc32(frame[:16] + payload) != crc:
        raise ValueError("CRC32 错误")
    return op, request_id, status, payload


def dds_word(hz: float, sample_rate: int) -> tuple[int, float]:
    if not math.isfinite(hz) or not 0 <= hz < sample_rate / 2:
        raise ValueError("DDS 频率超出范围")
    word = round(hz * PHASE_MOD / sample_rate)
    return word, word * sample_rate / PHASE_MOD


def custom_divider(hz: float, length: int, sample_rate: int) -> tuple[int, float]:
    if not math.isfinite(hz) or hz <= 0 or not 1 <= length <= MAX_POINTS:
        raise ValueError("自定义波形频率或长度无效")
    divider = round(sample_rate / (hz * length))
    if not 1 <= divider <= 0xFFFFFFFF:
        raise ValueError("此频率无法逐点播放")
    return divider, sample_rate / (divider * length)


def normalized_to_codes(values: list[float]) -> list[int]:
    if not 1 <= len(values) <= MAX_POINTS:
        raise ValueError("波形长度必须为 1～1048576 点")
    if any(not math.isfinite(x) or x < -1 or x > 1 for x in values):
        raise ValueError("CSV 样点必须为 [-1,1] 内的有限数")
    return [round(8191.5 * (x + 1)) for x in values]


def read_csv(path: str | Path) -> tuple[list[int], list[int] | None]:
    columns: list[list[float]] = [[], []]
    width = None
    with Path(path).open("r", encoding="utf-8-sig", newline="") as source:
        for line_number, row in enumerate(csv.reader(source), 1):
            if not row or all(not cell.strip() for cell in row):
                continue
            if width is None:
                width = len(row)
                if width not in (1, 2):
                    raise ValueError("CSV 只接受单列或双列")
            if len(row) != width:
                raise ValueError(f"第 {line_number} 行列数不一致")
            try:
                values = [float(cell) for cell in row]
            except ValueError as exc:
                raise ValueError(f"第 {line_number} 行不是数值") from exc
            for index, value in enumerate(values):
                columns[index].append(value)
            if len(columns[0]) > MAX_POINTS:
                raise ValueError("CSV 超过百万点上限")
    if width is None:
        raise ValueError("CSV 为空")
    return normalized_to_codes(columns[0]), normalized_to_codes(columns[1]) if width == 2 else None


class SocketTransport:
    max_chunk_points = (MAX_PAYLOAD - 8) // 2

    def __init__(self, host: str = "192.168.10.10", port: int = 5000, timeout: float = 3):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.settimeout(timeout)

    def write(self, data: bytes) -> None:
        self.sock.sendall(data)

    def read(self, count: int) -> bytes:
        output = bytearray()
        while len(output) < count:
            part = self.sock.recv(count - len(output))
            if not part:
                raise ConnectionError("设备断开连接")
            output.extend(part)
        return bytes(output)

    def close(self) -> None:
        self.sock.close()


class SerialTransport:
    max_chunk_points = 512

    def __init__(self, port: str, timeout: float = 2):
        import serial
        self.port = serial.Serial(port, 115200, timeout=timeout, write_timeout=timeout)
        self.port.reset_input_buffer()

    def write(self, data: bytes) -> None:
        self.port.write(data)

    def read(self, count: int) -> bytes:
        output = bytearray()
        while len(output) < count:
            part = self.port.read(count - len(output))
            if not part:
                raise TimeoutError("串口应答超时")
            output.extend(part)
        return bytes(output)

    def close(self) -> None:
        self.port.close()


class AWGDevice:
    """Idempotent request/retry client. Reconnect by replacing ``transport``."""

    def __init__(self, transport):
        self.transport = transport
        self.request_id = 1
        self.lock = threading.Lock()

    def request(self, op: int, payload: bytes = b"", retries: int = 3) -> bytes:
        with self.lock:
            request_id = self.request_id
            packet = encode_frame(op, request_id, payload)
            for _ in range(retries):
                try:
                    self.transport.write(packet)
                    head = self.transport.read(HEADER.size)
                    if len(head) != HEADER.size:
                        continue
                    length = HEADER.unpack(head)[5]
                    if length > MAX_PAYLOAD:
                        raise ValueError("设备返回的负载过长")
                    response = head + (self.transport.read(length) if length else b"")
                    response_op, response_id, status, data = decode_frame(response)
                    if response_op != (op | 0x80) or response_id != request_id:
                        continue
                    self.request_id = (self.request_id + 1) & 0xFFFFFFFF
                    if status:
                        raise RuntimeError(ERRORS.get(status, f"设备错误 {status}"))
                    return data
                except (TimeoutError, socket.timeout):
                    continue
            raise TimeoutError("设备没有返回有效应答")

    def info(self) -> tuple[int, int, int, int]:
        return struct.unpack("<BIII", self.request(INFO))

    def status(self) -> tuple[int, int, int, int]:
        return struct.unpack("<BBII", self.request(STATUS))

    def set_rate(self, sample_rate: int) -> None:
        if sample_rate not in (10_000_000, 25_000_000, 50_000_000):
            raise ValueError("采样率只能是 10/25/50 MSPS")
        self.request(RATE, struct.pack("<I", sample_rate))

    def configure(self, channel: int, *, arbitrary: bool, shape: int,
                  frequency: float, phase_degrees: float, gain: int,
                  offset: int, divider: int, sample_rate: int,
                  idle_code: int = 8192) -> float:
        if channel not in (1, 2) or shape not in range(4):
            raise ValueError("通道或波形无效")
        if not 0 <= gain <= 32768 or not -8192 <= offset <= 8191:
            raise ValueError("增益或偏置码超出范围")
        if not 1 <= divider <= 0xFFFFFFFF or not math.isfinite(phase_degrees) \
                or not 0 <= idle_code <= 16383:
            raise ValueError("分频或相位无效")
        word, actual = dds_word(frequency, sample_rate)
        phase = round((phase_degrees % 360) * PHASE_MOD / 360) % PHASE_MOD
        payload = struct.pack("<BBB Hh QQ IH", channel, int(arbitrary), shape,
                              gain, offset, word, phase, divider, idle_code)
        self.request(CONFIG, payload)
        return actual

    def apply(self, mask: int) -> None:
        self.request(APPLY, bytes([mask]))

    def upload(self, channel: int, codes: list[int], progress=None) -> None:
        if channel not in (1, 2) or not 1 <= len(codes) <= MAX_POINTS:
            raise ValueError("通道或波形长度无效")
        if any(not isinstance(x, int) or not 0 <= x <= 16383 for x in codes):
            raise ValueError("样点必须为 14 位无符号整数")
        packed = array("H", codes)
        if sys.byteorder != "little":
            packed.byteswap()
        all_bytes = packed.tobytes()
        digest = zlib.crc32(all_bytes)
        data = self.request(BEGIN, struct.pack("<BII", channel, len(codes), digest))
        upload_id, offset = struct.unpack("<II", data)
        block_points = min((MAX_PAYLOAD - 8) // 2,
                           getattr(self.transport, "max_chunk_points", (MAX_PAYLOAD - 8) // 2))
        while offset < len(codes):
            count = min(block_points, len(codes) - offset)
            part = all_bytes[2 * offset:2 * (offset + count)]
            try:
                answer = self.request(DATA, struct.pack("<II", upload_id, offset) + part)
                new_offset, = struct.unpack("<I", answer)
            except TimeoutError:
                new_offset, = struct.unpack("<I", self.request(QUERY_UPLOAD,
                                                               struct.pack("<I", upload_id)))
            if new_offset <= offset or new_offset > len(codes):
                raise RuntimeError("设备上传偏移未前进")
            offset = new_offset
            if progress:
                progress(offset, len(codes))
        self.request(END, struct.pack("<I", upload_id))

    def commit(self, mask: int) -> None:
        self.request(COMMIT, bytes([mask]))

    def arm(self, mask: int, cycles: int = 0, external: bool = False) -> None:
        if not 0 <= cycles <= 65535:
            raise ValueError("突发周期数无效")
        self.request(ARM, struct.pack("<BHB", mask, cycles, int(external)))

    def start(self, mask: int = 3) -> None:
        self.request(START, bytes([mask]))

    def stop(self, mask: int = 3) -> None:
        self.request(STOP, bytes([mask]))

    def clear_fault(self) -> None:
        self.request(CLEAR_FAULT)
