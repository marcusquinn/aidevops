#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Stdio MCP proxy for VoiceStudio's streamable-HTTP /mcp endpoint.

Run through `voicestudio-helper.sh mcp`, which injects the bearer key.
Requests and results are rewritten by voicestudio_mcp_files.py so audio stays
in local files instead of the model's context.
"""

from __future__ import annotations

import json
import re
import sys
import threading

from voicestudio_api import VoiceStudioError, request
from voicestudio_mcp_files import rewrite_call, rewrite_result

HEADERS = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}


class McpProxy:
    """Bridge MCP stdio (newline-delimited JSON-RPC) to VoiceStudio's /mcp endpoint."""

    def __init__(self) -> None:
        self.session: str | None = None
        self.init_message: dict | None = None
        self.lock = threading.Lock()
        self.write_lock = threading.Lock()

    def emit(self, message: dict) -> None:
        with self.write_lock:
            sys.stdout.write(json.dumps(message, separators=(",", ":")) + "\n")
            sys.stdout.flush()

    def error(self, message: dict, text: str) -> None:
        if "id" in message:
            self.emit({"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32000, "message": text}})

    def post(self, message: dict) -> tuple[int, list[dict]]:
        headers = dict(HEADERS, **({"Mcp-Session-Id": self.session} if self.session else {}))
        status, resp_headers, data = request("POST", "/mcp", json.dumps(message).encode(), headers)
        self.session = resp_headers.get("mcp-session-id") or self.session
        if status >= 400 or not data.strip():
            return status, []
        if "text/event-stream" in resp_headers.get("content-type", ""):
            return status, parse_sse(data.decode("utf-8", "replace"))
        parsed = json.loads(data)
        return status, parsed if isinstance(parsed, list) else [parsed]

    def reconnect(self) -> None:
        self.session = None
        if self.init_message:
            self.post(self.init_message)
            self.post({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def forward(self, message: dict) -> tuple[int, list[dict]]:
        """POST one message, starting a new session once if the server forgot ours."""
        method = message.get("method")
        if method == "initialize":
            self.init_message = message
        forwarded = rewrite_call(message) if method == "tools/call" else message
        status, replies = self.post(forwarded)
        if status == 404 and self.session is not None and method != "initialize":
            with self.lock:  # e.g. the server restarted
                self.reconnect()
            status, replies = self.post(forwarded)
        return status, replies

    def handle(self, message: dict) -> None:
        try:
            status, replies = self.forward(message)
            if status >= 400:
                self.error(message, f"VoiceStudio MCP returned HTTP {status}")
                return
            for reply in replies:
                if "result" in reply:
                    rewrite_result(message, reply["result"])
                self.emit(reply)
        except (VoiceStudioError, OSError, ValueError) as exc:
            self.error(message, str(exc))

    def run(self) -> int:
        for message in read_messages(sys.stdin):
            if message.get("method") == "initialize":
                self.handle(message)  # everything else needs the session it creates
            else:
                # Non-daemon: the interpreter waits for in-flight calls at end of input.
                threading.Thread(target=self.handle, args=(message,)).start()
        return 0


def read_messages(stream):
    for line in stream:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(message, dict):
            yield message


def parse_sse(text: str) -> list[dict]:
    messages = []
    for event in re.split(r"\r?\n\r?\n", text):
        data = "\n".join(line[5:].lstrip() for line in event.splitlines() if line.startswith("data:"))
        if data:
            messages.append(json.loads(data))
    return messages
