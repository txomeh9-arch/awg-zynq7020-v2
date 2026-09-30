"""Protocol reference model for offline host tests; it does not emulate FPGA timing."""
from __future__ import annotations

import struct
import time
import zlib
from array import array
from dataclasses import dataclass

from host.protocol import (APPLY, ARM, BEGIN, CLEAR_FAULT, COMMIT, CONFIG, DATA,
                           END, INFO, MAX_POINTS, QUERY_UPLOAD, RATE, START,
                           STATUS, STOP, decode_frame, encode_frame)


@dataclass
class Upload:
    token: int
    channel: int
    length: int
    expected_crc: int
    samples: bytearray
    offset: int = 0
    complete: bool = False
    last_activity: float = 0


class DeviceModel:
    def __init__(self):
        self.sample_rate = 10_000_000
        self.run_mask = 0
        self.faults = 0
        self.underruns = [0, 0]
        self.shadow = [None, None]
        self.active_config = [None, None]
        self.active_wave = [None, None]
        self.ready = [None, None]
        self.upload: Upload | None = None
        self.next_token = 1
        self.cache: tuple[object, int, bytes, bytes] | None = None
        self.owner = None
        self.last_owner_activity = 0.0
        self.armed_mask = 0

    def _execute(self, op: int, payload: bytes, session) -> tuple[int, bytes]:
        if op == INFO and not payload:
            return 0, struct.pack("<BIII", 2, 2, self.sample_rate, MAX_POINTS)
        if op == STATUS and not payload:
            return 0, struct.pack("<BBII", self.run_mask, self.faults, *self.underruns)
        if op == STOP and len(payload) == 1:
            self.run_mask &= ~payload[0]
            self.armed_mask &= ~payload[0]
            return 0, b""
        if op == CLEAR_FAULT and not payload:
            self.faults = 0
            return 0, b""
        if self.owner is not None and self.owner != session and time.monotonic() - self.last_owner_activity < 30:
            return 6, b""
        self.owner, self.last_owner_activity = session, time.monotonic()
        if op == RATE and len(payload) == 4:
            rate, = struct.unpack("<I", payload)
            if rate not in (10_000_000, 25_000_000, 50_000_000):
                return 4, b""
            self.run_mask = 0
            self.armed_mask = 0
            self.sample_rate = rate
            return 0, b""
        if op == CONFIG and len(payload) == struct.calcsize("<BBB Hh QQ IH"):
            channel, mode, shape, gain, offset, step, phase, divider, idle = struct.unpack(
                "<BBB Hh QQ IH", payload)
            if channel not in (1, 2) or mode not in (0, 1) or shape > 3 or gain > 32768 \
                    or not -8192 <= offset <= 8191 or step >= 1 << 48 \
                    or phase >= 1 << 48 or not divider or idle > 16383:
                return 3, b""
            self.shadow[channel - 1] = payload
            return 0, b""
        if op == APPLY and len(payload) == 1:
            mask = payload[0]
            if mask not in (1, 2, 3) or any(self.shadow[i] is None for i in range(2) if mask & (1 << i)):
                return 4, b""
            for i in range(2):
                if mask & (1 << i):
                    self.active_config[i] = self.shadow[i]
            return 0, b""
        if op == BEGIN and len(payload) == 9:
            channel, length, expected_crc = struct.unpack("<BII", payload)
            if channel not in (1, 2) or not 1 <= length <= MAX_POINTS:
                return 3, b""
            if self.upload and not self.upload.complete and self.upload.channel == channel \
                    and self.upload.length == length and self.upload.expected_crc == expected_crc:
                return 0, struct.pack("<II", self.upload.token, self.upload.offset)
            self.upload = Upload(self.next_token, channel, length, expected_crc,
                                 bytearray(length * 2), last_activity=time.monotonic())
            self.next_token += 1
            return 0, struct.pack("<II", self.upload.token, 0)
        if op == DATA and len(payload) >= 10 and (len(payload) - 8) % 2 == 0:
            token, offset = struct.unpack_from("<II", payload)
            upload = self.upload
            if not upload or token != upload.token or upload.complete:
                return 5, b""
            part = payload[8:]
            if offset == upload.offset and offset + len(part) // 2 <= upload.length:
                samples = array("H")
                samples.frombytes(part)
                if any(code > 16383 for code in samples):
                    return 3, b""
                upload.samples[2 * offset:2 * offset + len(part)] = part
                upload.offset += len(part) // 2
                upload.last_activity = time.monotonic()
                return 0, struct.pack("<I", upload.offset)
            if offset < upload.offset and upload.samples[2 * offset:2 * offset + len(part)] == part:
                return 0, struct.pack("<I", upload.offset)
            return 5, b""
        if op == QUERY_UPLOAD and len(payload) == 4:
            token, = struct.unpack("<I", payload)
            if self.upload and token == self.upload.token:
                return 0, struct.pack("<I", self.upload.offset)
            return 5, b""
        if op == END and len(payload) == 4:
            token, = struct.unpack("<I", payload)
            upload = self.upload
            if not upload or token != upload.token or upload.offset != upload.length:
                return 5, b""
            if zlib.crc32(upload.samples) != upload.expected_crc:
                return 1, b""
            upload.complete = True
            self.ready[upload.channel - 1] = bytes(upload.samples)
            return 0, b""
        if op == COMMIT and len(payload) == 1:
            mask = payload[0]
            if mask not in (1, 2, 3) or any(self.ready[i] is None for i in range(2) if mask & (1 << i)):
                return 4, b""
            for i in range(2):
                if mask & (1 << i):
                    self.active_wave[i], self.ready[i] = self.ready[i], None
            return 0, b""
        if op == ARM and len(payload) == 4:
            mask, cycles, external = struct.unpack("<BHB", payload)
            if mask not in (1, 2, 3) or external not in (0, 1):
                return 3, b""
            self.armed_mask = mask
            return 0, b""
        if op == START and len(payload) == 1:
            mask = payload[0]
            if mask not in (1, 2, 3) or mask & ~self.armed_mask or self.faults:
                return 4, b""
            self.run_mask |= mask
            self.armed_mask &= ~mask
            return 0, b""
        return 8, b""

    def process(self, frame: bytes, session="default") -> bytes:
        try:
            op, request_id, _status, payload = decode_frame(frame)
        except ValueError:
            return b""  # Invalid frame is discarded; client retries same ID.
        if self.cache and self.cache[:3] == (session, request_id, frame):
            return self.cache[3]
        if self.cache and self.cache[:2] == (session, request_id):
            return b""
        status, answer = self._execute(op, payload, session)
        response = encode_frame(op | 0x80, request_id, answer, status=status)
        self.cache = session, request_id, frame, response
        return response
