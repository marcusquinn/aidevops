#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Client for a self-hosted VoiceStudio speech server (standard library only).

VoiceStudio (github.com/debpalash/VoiceStudio) serves OpenAI-compatible speech
and transcription endpoints plus a streamable-HTTP MCP endpoint. This client is
what voicestudio-helper.sh runs; call the helper, not this file, so the API key
is injected from aidevops secrets.

Commands: status, voices, speak, transcribe, clone, mcp (stdio proxy).

Environment:
  VOICESTUDIO_URL         server base URL (default http://127.0.0.1:3900;
                          OMNIVOICE_URL is accepted as a fallback)
  VOICESTUDIO_SECRET      name of the variable holding the key
                          (default OMNIVOICE_API_KEY)
  VOICESTUDIO_OUTPUT_DIR  where the MCP proxy saves generated audio
  VOICESTUDIO_TIMEOUT     per-request timeout in seconds (default 600)
  VOICESTUDIO_RETRY_DELAY seconds before the first 5xx retry (default 30)
"""

from __future__ import annotations

import argparse
import base64
import io
import json
import os
import re
import shutil
import subprocess  # nosec B404 -- ffmpeg conversion only, fixed argv; see write_audio
import sys
import tempfile
import threading
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


def timeout() -> float:
    return float(os.environ.get("VOICESTUDIO_TIMEOUT", "600"))


def request(method: str, path: str, body: bytes | None = None,
            headers: dict[str, str] | None = None) -> tuple[int, dict[str, str], bytes]:
    """Send one request; HTTP errors are returned, not raised."""
    all_headers = dict(headers or {})
    key = api_key()
    if key:
        all_headers["Authorization"] = f"Bearer {key}"
    req = urllib.request.Request(base_url() + path, data=body, headers=all_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout()) as resp:  # nosec B310 -- base_url() allows http(s) only
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


# ---------- text and audio ----------


SENTENCE_END = re.compile(r"(?<=[.!?\u2026\u3002\uff01\uff1f])\s+")
CLAUSE_END = re.compile(r"(?<=[,;:\u2014\u3001\uff0c\uff1b])\s*")


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


def synth(text: str, opts: argparse.Namespace, fmt: str = "wav") -> bytes:
    payload = {"model": opts.model, "input": text, "voice": opts.voice,
               "response_format": fmt, "speed": opts.speed}
    if opts.language:
        payload["language"] = opts.language
    if opts.instruct:
        payload["instruct"] = opts.instruct
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


# ---------- commands ----------


def cmd_status(opts: argparse.Namespace) -> int:
    status, _, data = request("GET", "/health")
    print(f"URL:     {base_url()}")
    print(f"Health:  HTTP {status} {data[:120].decode('utf-8', 'replace').strip()}")
    status, _, data = request("GET", "/v1/models")
    if status == 401:
        print("Auth:    rejected (store OMNIVOICE_API_KEY with `aidevops secret set`)")
        return 1
    check(status, data, "GET /v1/models")
    print("Auth:    ok" if api_key() else "Auth:    ok (no key needed)")
    engines = get_json("/engines/tts")
    active = next((b for b in engines.get("backends", []) if b.get("id") == engines.get("active")), {})
    print(f"Engine:  {engines.get('active')} ({engines.get('active_model')}) on "
          f"{active.get('effective_device', 'unknown')}, cloning: {active.get('supports_cloning')}")
    if opts.json:
        print(json.dumps(engines, indent=2))
    return 0


def cmd_voices(opts: argparse.Namespace) -> int:
    profiles = get_json("/profiles")
    if opts.json:
        print(json.dumps(profiles, indent=2))
        return 0
    print("id\tkind\tlanguage\tname")
    for p in profiles:
        print(f"{p.get('id')}\t{p.get('kind')}\t{p.get('language') or '-'}\t{p.get('name')}")
    print("OpenAI names (alloy, nova, ...) and 'default' map to the engine default voice.",
          file=sys.stderr)
    return 0


def read_text(opts: argparse.Namespace) -> str:
    if opts.text:
        return opts.text
    if opts.file:
        return Path(opts.file).read_text(encoding="utf-8")
    if sys.stdin.isatty():
        raise VoiceStudioError("give --text, --file, or text on stdin")
    return sys.stdin.read()


def cmd_speak(opts: argparse.Namespace) -> int:
    text = read_text(opts).strip()
    if not text:
        raise VoiceStudioError("no text to speak")
    out = Path(opts.out)
    pieces = split_text(text, opts.max_chars)
    ext = out.suffix.lower().lstrip(".")
    started = time.monotonic()
    if len(pieces) == 1 and ext in NATIVE_FORMATS:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(synth(pieces[0][0], opts, ext))
    else:
        clips = []
        for index, (piece, pause) in enumerate(pieces, 1):
            print(f"[voicestudio] piece {index}/{len(pieces)} ({len(piece)} chars)",
                  file=sys.stderr, flush=True)
            clips.append((synth(piece, opts), pause))
        write_audio(join_wavs(clips), out)
    print(f"{out} ({len(pieces)} piece(s), {time.monotonic() - started:.1f}s)")
    return 0


def cmd_transcribe(opts: argparse.Namespace) -> int:
    fields = {"model": "whisper-1", "response_format": opts.format}
    if opts.language:
        fields["language"] = opts.language
    data = post_multipart("/v1/audio/transcriptions", fields, {"file": Path(opts.audio)})
    text = json.loads(data).get("text", "") if opts.format == "json" else data.decode("utf-8")
    if opts.out:
        Path(opts.out).write_text(text, encoding="utf-8")
        print(opts.out)
    else:
        print(text)
    return 0


def cmd_clone(opts: argparse.Namespace) -> int:
    fields = {"name": opts.name, "ref_text": opts.ref_text or "", "language": opts.language or "Auto"}
    if opts.instruct:
        fields["instruct"] = opts.instruct
    profile = json.loads(post_multipart("/profiles", fields, {"ref_audio": Path(opts.ref)}))
    print(f"{profile.get('id')}\t{profile.get('name')}")
    return 0


# ---------- MCP stdio proxy ----------


def output_dir() -> Path:
    configured = os.environ.get("VOICESTUDIO_OUTPUT_DIR")
    if configured:
        return Path(configured).expanduser()
    temp = os.environ.get("AIDEVOPS_TEMP_DIR") or str(Path.home() / ".aidevops/.agent-workspace/tmp")
    return Path(temp) / "voicestudio"


# Local-file arguments the proxy adds, so audio never passes through the model's context.
LOCAL_ARGS = {
    "generate_speech": ("output_path", "Local file to write the WAV to (default: a file under "
                        "VOICESTUDIO_OUTPUT_DIR). The proxy returns audio_path instead of base64."),
    "clone_voice": ("ref_audio_file", "Local reference audio file (5-30 s, one speaker); "
                    "the proxy uploads it as ref_audio_base64."),
    "transcribe": ("audio_file", "Local audio file; the proxy uploads it as audio_base64."),
}
UPLOAD_TARGET = {"clone_voice": "ref_audio_base64", "transcribe": "audio_base64"}


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
        headers = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        status, resp_headers, data = request("POST", "/mcp", json.dumps(message).encode(), headers)
        if resp_headers.get("mcp-session-id"):
            self.session = resp_headers["mcp-session-id"]
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
        if message.get("method") == "initialize":
            self.init_message = message
        forwarded = rewrite_call(message) if message.get("method") == "tools/call" else message
        status, replies = self.post(forwarded)
        if status == 404 and self.session is not None and message.get("method") != "initialize":
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
        threads = []
        for line in sys.stdin:
            if not line.strip():
                continue
            try:
                message = json.loads(line)
            except json.JSONDecodeError:
                continue
            if message.get("method") == "initialize":
                self.handle(message)  # everything else needs the session it creates
                continue
            thread = threading.Thread(target=self.handle, args=(message,), daemon=True)
            thread.start()
            threads.append(thread)
        for thread in threads:
            thread.join()
        return 0


def parse_sse(text: str) -> list[dict]:
    messages = []
    for event in re.split(r"\r?\n\r?\n", text):
        data = "\n".join(line[5:].lstrip() for line in event.splitlines() if line.startswith("data:"))
        if data:
            messages.append(json.loads(data))
    return messages


def add_local_args(tools: list[dict]) -> None:
    for tool in tools:
        extra = LOCAL_ARGS.get(tool.get("name"))
        if extra:
            props = tool.setdefault("inputSchema", {}).setdefault("properties", {})
            props[extra[0]] = {"type": "string", "description": extra[1]}


def rewrite_call(message: dict) -> dict:
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
    """Advertise the proxy's local-file arguments and keep audio out of tool results."""
    method = request_message.get("method")
    params = request_message.get("params", {})
    if method == "tools/list":
        add_local_args(result.get("tools", []))
    elif method == "tools/call" and params.get("name") == "generate_speech":
        save_speech(result, params.get("arguments", {}))


def _json_holders(result: dict) -> list[tuple[dict, str, dict]]:
    """(container, key, parsed JSON) for every JSON object string in a tool result.

    VoiceStudio repeats one JSON string in content[].text and structuredContent.result.
    """
    candidates = [(item, "text") for item in result.get("content", []) if item.get("type") == "text"]
    structured = result.get("structuredContent")
    if isinstance(structured, dict):
        candidates.append((structured, "result"))
    holders = []
    for container, key in candidates:
        try:
            body = json.loads(container.get(key) or "")
        except (TypeError, json.JSONDecodeError):
            continue
        if isinstance(body, dict):
            holders.append((container, key, body))
    return holders


def save_speech(result: dict, args: dict) -> None:
    """Write inline base64 audio to a file and return audio_path instead, in every copy."""
    saved: str | None = None
    for container, key, body in _json_holders(result):
        audio = body.pop("wav_base64", None)
        if not audio:
            continue
        saved = saved or _write_wav(audio, args.get("output_path"), body.get("audio_id"))
        body["audio_path"] = saved
        container[key] = json.dumps(body)


def _write_wav(audio_b64: str, target: str | None, audio_id: str | None) -> str:
    path = Path(target).expanduser() if target else output_dir() / f"{audio_id or uuid.uuid4().hex[:8]}.wav"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(base64.b64decode(audio_b64))
    return str(path.resolve())


def cmd_mcp(_opts: argparse.Namespace) -> int:
    return McpProxy().run()


# ---------- CLI ----------


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="voicestudio-helper.sh", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="command", required=True)

    s = sub.add_parser("status", help="health, auth and active engine")
    s.add_argument("--json", action="store_true", help="also print every engine")
    s.set_defaults(func=cmd_status)

    s = sub.add_parser("voices", help="list saved voice profiles")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_voices)

    s = sub.add_parser("speak", help="text to an audio file (long text is split and joined)")
    s.add_argument("--text")
    s.add_argument("--file", help="UTF-8 text file (blank lines = paragraph pauses)")
    s.add_argument("--out", required=True, help=".wav, or .mp3/.flac/.opus/... (ffmpeg for long text)")
    s.add_argument("--voice", default="default", help="profile id from `voices`, or 'default'")
    s.add_argument("--language", help="ISO code, e.g. en, fr, hi (default: engine auto-detect)")
    s.add_argument("--instruct", help="style instruction, e.g. 'calm narrator'")
    s.add_argument("--speed", type=float, default=1.0)
    s.add_argument("--model", default="tts-1", help="tts-1 = active engine, or an engine id")
    s.add_argument("--max-chars", type=int, default=DEFAULT_MAX_CHARS)
    s.add_argument("--retries", type=int, default=3)
    s.set_defaults(func=cmd_speak)

    s = sub.add_parser("transcribe", help="speech to text")
    s.add_argument("audio")
    s.add_argument("--language")
    s.add_argument("--format", default="json", choices=["json", "text", "srt", "vtt", "verbose_json"])
    s.add_argument("--out")
    s.set_defaults(func=cmd_transcribe)

    s = sub.add_parser("clone", help="save a voice profile from 5-30 s of clean reference audio")
    s.add_argument("--name", required=True)
    s.add_argument("--ref", required=True, help="reference audio file")
    s.add_argument("--ref-text", help="transcript of the reference (improves quality)")
    s.add_argument("--language")
    s.add_argument("--instruct")
    s.set_defaults(func=cmd_clone)

    s = sub.add_parser("mcp", help="stdio MCP proxy for agents")
    s.set_defaults(func=cmd_mcp)
    return p


def main(argv: list[str] | None = None) -> int:
    opts = parser().parse_args(argv)
    try:
        return opts.func(opts)
    except VoiceStudioError as exc:
        print(f"voicestudio: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
