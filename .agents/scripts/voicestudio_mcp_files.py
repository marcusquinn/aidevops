#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Local-file rewriting for the VoiceStudio MCP proxy (voicestudio_mcp.py).

Audio never passes through the model's context: generate_speech output is
written to a file and returned as `audio_path`, and clone_voice / transcribe
take a local file that the proxy reads and uploads.

Environment: VOICESTUDIO_OUTPUT_DIR (default $AIDEVOPS_TEMP_DIR/voicestudio,
else ~/.aidevops/.agent-workspace/tmp/voicestudio).
"""

from __future__ import annotations

import base64
import json
import os
import uuid
from pathlib import Path

LOCAL_ARGS = {
    "generate_speech": ("output_path", "Local file to write the WAV to (default: a file under "
                        "VOICESTUDIO_OUTPUT_DIR). The proxy returns audio_path instead of base64."),
    "clone_voice": ("ref_audio_file", "Local reference audio file (5-30 s, one speaker); "
                    "the proxy uploads it as ref_audio_base64."),
    "transcribe": ("audio_file", "Local audio file; the proxy uploads it as audio_base64."),
}
UPLOAD_TARGET = {"clone_voice": "ref_audio_base64", "transcribe": "audio_base64"}


def rewrite_call(message: dict) -> dict:
    """Replace the proxy's local-file arguments with what the server expects."""
    message = json.loads(json.dumps(message))
    params = message.get("params", {})
    tool = params.get("name")
    args = params.setdefault("arguments", {})
    if tool == "generate_speech":
        args.pop("output_path", None)  # applied when the result comes back
    elif tool in UPLOAD_TARGET:
        local = args.pop(LOCAL_ARGS[tool][0], None)
        if local:
            args[UPLOAD_TARGET[tool]] = base64.b64encode(Path(local).expanduser().read_bytes()).decode()
    return message


def rewrite_result(request_message: dict, result: dict) -> None:
    """Advertise the local-file arguments and keep audio out of tool results."""
    params = request_message.get("params", {})
    if request_message.get("method") == "tools/list":
        for tool in result.get("tools", []):
            extra = LOCAL_ARGS.get(tool.get("name"))
            if extra:
                props = tool.setdefault("inputSchema", {}).setdefault("properties", {})
                props[extra[0]] = {"type": "string", "description": extra[1]}
    elif params.get("name") == "generate_speech":
        save_speech(result, params.get("arguments", {}))


def _as_object(text) -> dict | None:
    try:
        value = json.loads(text)
    except (TypeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def save_speech(result: dict, args: dict) -> None:
    """Write inline base64 audio to a file and return audio_path instead.

    VoiceStudio repeats one JSON string in content[].text and structuredContent.result,
    so every copy is rewritten.
    """
    holders = [(item, "text") for item in result.get("content", []) if item.get("type") == "text"]
    if isinstance(result.get("structuredContent"), dict):
        holders.append((result["structuredContent"], "result"))
    saved: str | None = None
    for container, key in holders:
        body = _as_object(container.get(key))
        audio = body.pop("wav_base64", None) if body else None
        if audio:
            saved = saved or _write_wav(audio, args.get("output_path"), body.get("audio_id"))
            body["audio_path"] = saved
            container[key] = json.dumps(body)


def output_dir() -> Path:
    configured = os.environ.get("VOICESTUDIO_OUTPUT_DIR")
    if configured:
        return Path(configured).expanduser()
    temp = os.environ.get("AIDEVOPS_TEMP_DIR") or str(Path.home() / ".aidevops/.agent-workspace/tmp")
    return Path(temp) / "voicestudio"


def _write_wav(audio_b64: str, target: str | None, audio_id: str | None) -> str:
    path = Path(target).expanduser() if target else output_dir() / f"{audio_id or uuid.uuid4().hex[:8]}.wav"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(base64.b64decode(audio_b64))
    return str(path.resolve())
