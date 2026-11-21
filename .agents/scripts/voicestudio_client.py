#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Client for a self-hosted VoiceStudio speech server (standard library only).

VoiceStudio (github.com/debpalash/VoiceStudio) serves OpenAI-compatible speech
and transcription endpoints plus a streamable-HTTP MCP endpoint. This client is
what voicestudio-helper.sh runs; call the helper, not this file, so the API key
is injected from aidevops secrets.

Commands: status, voices, speak, transcribe, clone, mcp (stdio proxy).
Modules: voicestudio_api.py (HTTP, text, audio), voicestudio_mcp.py (proxy).
Environment variables are listed in those modules' docstrings.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from voicestudio_api import (
    DEFAULT_MAX_CHARS,
    NATIVE_FORMATS,
    VoiceStudioError,
    api_key,
    base_url,
    check,
    get_json,
    join_wavs,
    post_multipart,
    request,
    split_text,
    synth,
    write_audio,
)


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


def cmd_mcp(_opts: argparse.Namespace) -> int:
    from voicestudio_mcp import McpProxy

    return McpProxy().run()


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
