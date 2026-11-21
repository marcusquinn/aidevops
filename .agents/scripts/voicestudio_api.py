#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""HTTP, text-splitting and WAV helpers for voicestudio_client.py (standard library only).

Environment:
  VOICESTUDIO_URL         server base URL (default http://127.0.0.1:3900;
                          OMNIVOICE_URL is accepted as a fallback)
  VOICESTUDIO_SECRET      name of the variable holding the key
                          (default OMNIVOICE_API_KEY)
  VOICESTUDIO_TIMEOUT     per-request timeout in seconds (default 600)
  VOICESTUDIO_RETRY_DELAY seconds before the first 5xx retry (default 30)
"""

from __future__ import annotations

import io
import json
import os
import re
import shutil
import subprocess  # nosec B404 -- ffmpeg conversion only, fixed argv; see write_audio
import sys
import tempfile
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path

DEFAULT_URL = "http://127.0.0.1:3900"
# VoiceStudio abandons a request after about 300 s of GPU time (HTTP 503). On a
# slow GPU a long sentence gets there, so text is spoken in pieces of this size.
DEFAULT_MAX_CHARS = 220
NATIVE_FORMATS = {"mp3", "opus", "aac", "flac", "wav"}
SENTENCE_END = re.compile(r"(?<=[.!?\u2026\u3002\uff01\uff1f])\s+")
CLAUSE_END = re.compile(r"(?<=[,;:\u2014\u3001\uff0c\uff1b])\s*")


class VoiceStudioError(RuntimeError):
    """A request the server refused or could not complete."""


# ---------- HTTP ----------


def base_url() -> str:
    url = os.environ.get("VOICESTUDIO_URL") or os.environ.get("OMNIVOICE_URL") or DEFAULT_URL
    if not url.startswith(("http://", "https://")):
        raise VoiceStudioError(f"VOICESTUDIO_URL must be an http(s) URL, got {url!r}")
    return url.rstrip("/")


def api_key() -> str:
    name = os.environ.get("VOICESTUDIO_SECRET", "OMNIVOICE_API_KEY")
    return os.environ.get(name, "")


def request(method: str, path: str, body: bytes | None = None,
            headers: dict[str, str] | None = None) -> tuple[int, dict[str, str], bytes]:
    """Send one request; HTTP errors are returned, not raised."""
    all_headers = dict(headers or {})
    key = api_key()
    if key:
        all_headers["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(base_url() + path, data=body, headers=all_headers, method=method)
    wait = float(os.environ.get("VOICESTUDIO_TIMEOUT", "600"))
    try:
        with urllib.request.urlopen(req, timeout=wait) as resp:  # nosec B310 -- base_url() allows http(s) only
            return resp.status, {k.lower(): v for k, v in resp.headers.items()}, resp.read()
    except urllib.error.HTTPError as exc:
        return exc.code, {k.lower(): v for k, v in exc.headers.items()}, exc.read()
    except urllib.error.URLError as exc:
        raise VoiceStudioError(f"cannot reach {base_url()}: {exc.reason}") from exc


def check(status: int, data: bytes, what: str) -> None:
    if status == 401:
        raise VoiceStudioError(f"{what}: 401 unauthorised - store the key with "
                               "`aidevops secret set OMNIVOICE_API_KEY`")
    if status >= 400:
        detail = data[:300].decode("utf-8", "replace").strip()
        raise VoiceStudioError(f"{what}: HTTP {status} {detail}")


def get_json(path: str):
    status, _, data = request("GET", path)
    check(status, data, f"GET {path}")
    return json.loads(data)


def post_multipart(path: str, fields: dict[str, str], files: dict[str, Path]) -> bytes:
    boundary = uuid.uuid4().hex
    out = io.BytesIO()
    for name, value in fields.items():
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        out.write(str(value).encode() + b"\r\n")
    for name, file_path in files.items():
        out.write(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"; '
                  f'filename="{file_path.name}"\r\n'
                  "Content-Type: application/octet-stream\r\n\r\n".encode())
        out.write(file_path.read_bytes() + b"\r\n")
    out.write(f"--{boundary}--\r\n".encode())
    status, _, data = request("POST", path, out.getvalue(),
                              {"Content-Type": f"multipart/form-data; boundary={boundary}"})
    check(status, data, f"POST {path}")
    return data


# ---------- text ----------


def split_text(text: str, limit: int) -> list[tuple[str, float]]:
    """Split text into (piece, pause-after-seconds) at paragraph, sentence, then clause breaks."""
    pieces: list[tuple[str, float]] = []
    for paragraph in re.split(r"\n\s*\n", text):
        parts = [clause for sentence in SENTENCE_END.split(" ".join(paragraph.split()))
                 for clause in _clauses(sentence, limit)]
        packed = _pack(parts, limit)
        pieces += [(piece, 0.3) for piece in packed[:-1]] + [(piece, 0.7) for piece in packed[-1:]]
    return pieces


def _clauses(text: str, limit: int) -> list[str]:
    """Break one sentence into clause-sized parts; over-long clauses are cut at spaces."""
    if len(text) <= limit:
        return [text] if text else []
    return [cut for part in CLAUSE_END.split(text) for cut in _hard_wrap(part, limit)]


def _hard_wrap(part: str, limit: int) -> list[str]:
    out = []
    while len(part) > limit:
        cut = part.rfind(" ", 0, limit)
        cut = cut if cut > limit // 2 else limit
        out.append(part[:cut].strip())
        part = part[cut:].strip()
    return out + [part] if part else out


def _pack(parts: list[str], limit: int) -> list[str]:
    """Greedily join consecutive parts into pieces of at most `limit` characters."""
    out: list[str] = []
    for part in filter(None, parts):
        if out and len(out[-1]) + len(part) + 1 <= limit:
            out[-1] = f"{out[-1]} {part}"
        else:
            out.append(part)
    return out


# ---------- speech and audio ----------


def synth(text: str, opts, fmt: str = "wav") -> bytes:
    """One /v1/audio/speech request, retried on 5xx (a busy or out-of-memory GPU)."""
    payload = {"model": opts.model, "input": text, "voice": opts.voice,
               "response_format": fmt, "speed": opts.speed}
    payload.update({k: v for k, v in (("language", opts.language), ("instruct", opts.instruct)) if v})
    delay = float(os.environ.get("VOICESTUDIO_RETRY_DELAY", "30"))
    for attempt in range(opts.retries + 1):
        status, _, data = request("POST", "/v1/audio/speech", json.dumps(payload).encode(),
                                  {"Content-Type": "application/json"})
        if status < 500 or attempt == opts.retries:
            break
        # An abandoned GPU job keeps the device busy until it finishes.
        print(f"[voicestudio] HTTP {status}, retrying in {delay * (attempt + 1):.0f}s",
              file=sys.stderr, flush=True)
        time.sleep(delay * (attempt + 1))
    check(status, data, "speech")
    return data


def join_wavs(chunks: list[tuple[bytes, float]]) -> bytes:
    """Concatenate WAV clips with silence; every clip must share one format."""
    out = io.BytesIO()
    params = None
    with wave.open(out, "wb") as writer:
        for index, (clip, pause) in enumerate(chunks):
            with wave.open(io.BytesIO(clip), "rb") as reader:
                clip_params = reader.getparams()[:3]
                if params is None:
                    params = clip_params
                    writer.setnchannels(params[0])
                    writer.setsampwidth(params[1])
                    writer.setframerate(params[2])
                elif clip_params != params:
                    raise VoiceStudioError(f"clip {index} format {clip_params} differs from {params}")
                writer.writeframes(reader.readframes(reader.getnframes()))
            if index < len(chunks) - 1 and pause > 0:
                writer.writeframes(b"\0" * int(params[2] * pause) * params[0] * params[1])
    return out.getvalue()


def write_audio(wav: bytes, out: Path) -> None:
    out.parent.mkdir(parents=True, exist_ok=True)
    if out.suffix.lower() == ".wav":
        out.write_bytes(wav)
        return
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise VoiceStudioError(f"ffmpeg is needed to write {out.suffix} from several pieces; use .wav")
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        tmp.write(wav)
        tmp.flush()
        # Absolute output path, so a name starting with "-" is never read as an option.
        argv = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-i", tmp.name, str(out.resolve())]
        subprocess.run(argv, check=True)  # nosec B603 -- resolved ffmpeg, fixed argv, no shell
