# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Transparent terminal byte relay; only the private PID marker is consumed."""

import os
import re


class MarkerReader:
    def __init__(self, marker, connected):
        self.prefix = marker.encode()
        self.connected = connected
        self.pending = b""
        self.found = False

    def consume(self, byte):
        if self.found:
            return bytes([byte])
        self.pending += bytes([byte])
        if self.pending.startswith(self.prefix):
            return self.consume_suffix()
        if self.prefix.startswith(self.pending):
            return b""
        return self.drain()

    def consume_suffix(self):
        suffix = self.pending[len(self.prefix):]
        if re.fullmatch(rb"[0-9]+\r?\n", suffix):
            self.connected(suffix.strip().decode())
            self.pending, self.found = b"", True
        if len(suffix) > 32:
            return self.drain()
        return b""

    def drain(self):
        pending, self.pending = self.pending, b""
        return pending


def relay_output(stream, marker, connected, output):
    reader = MarkerReader(marker, connected)
    while True:
        chunk = os.read(stream.fileno(), 4096)
        if not chunk:
            break
        if not reader.found:
            chunk = b"".join(reader.consume(byte) for byte in chunk)
        output.write(chunk)
        output.flush()
    output.write(reader.drain())
    output.flush()
