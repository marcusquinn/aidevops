#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
CLI entry point and device/voice listing helpers for voice-bridge.py.

Extracted from voice-bridge.py to reduce file complexity.
"""

import argparse
import asyncio
import logging

import sounddevice as sd

from voice_stt import WhisperMLXSTT, FasterWhisperSTT, MacOSDictationSTT
from voice_tts import EdgeTTS, MacOSSayTTS, FacebookMMSTTS
from voice_llm import OpenCodeBridge

log = logging.getLogger("voice-bridge")


def create_stt(engine):
    """Create STT engine by name."""
    engines = {
        "whisper-mlx": WhisperMLXSTT,
        "faster-whisper": FasterWhisperSTT,
        "macos-dictation": MacOSDictationSTT,
    }
    if engine not in engines:
        import sys
        log.error(f"Unknown STT engine: {engine}. Available: {list(engines.keys())}")
        sys.exit(1)
    return engines[engine]()


def create_tts(engine, voice=None, rate=None):
    """Create TTS engine by name."""
    defaults = {
        "edge-tts": ("en-GB-SoniaNeural", EdgeTTS),
        "macos-say": ("Samantha", MacOSSayTTS),
        "facebookMMS": (None, FacebookMMSTTS),
    }
    if engine not in defaults:
        import sys
        log.error(f"Unknown TTS engine: {engine}. Available: {list(defaults.keys())}")
        sys.exit(1)

    default_voice, cls = defaults[engine]
    if voice is None:
        voice = default_voice

    if engine == "facebookMMS":
        return cls()
    if engine == "edge-tts":
        return cls(voice=voice, rate=rate or "+20%")
    return cls(voice=voice)


def parse_args():
    """Parse command line arguments."""
    parser = argparse.ArgumentParser(
        description="aidevops Voice Bridge - Talk to OpenCode",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s                                    # defaults: whisper-mlx + edge-tts
  %(prog)s --stt faster-whisper               # use faster-whisper STT
  %(prog)s --tts macos-say                    # use macOS say (offline)
  %(prog)s --tts-voice en-US-AriaNeural       # change edge-tts voice
  %(prog)s --model opencode/claude-opus-4-6   # use different model
  %(prog)s --input-device 7 --output-device 8 # MacBook mic + speakers
        """,
    )
    parser.add_argument(
        "--stt",
        choices=["whisper-mlx", "faster-whisper", "macos-dictation"],
        default="whisper-mlx",
        help="Speech-to-text engine (default: whisper-mlx)",
    )
    parser.add_argument(
        "--tts",
        choices=["edge-tts", "macos-say", "facebookMMS"],
        default="edge-tts",
        help="Text-to-speech engine (default: edge-tts)",
    )
    parser.add_argument(
        "--tts-voice",
        default=None,
        help="TTS voice name (default: en-GB-SoniaNeural)",
    )
    parser.add_argument(
        "--tts-rate",
        default="+20%",
        help="TTS speaking rate, e.g. +20%% (default: +20%%)",
    )
    parser.add_argument(
        "--model",
        default="opencode/claude-sonnet-4-6",
        help="OpenCode model (default: opencode/claude-sonnet-4-6)",
    )
    parser.add_argument(
        "--cwd",
        default=None,
        help="Working directory for OpenCode (default: current dir)",
    )
    parser.add_argument(
        "--input-device",
        type=int,
        default=None,
        help="Audio input device index (run with --list-devices to see options)",
    )
    parser.add_argument(
        "--output-device",
        type=int,
        default=None,
        help="Audio output device index",
    )
    parser.add_argument(
        "--list-devices",
        action="store_true",
        help="List audio devices and exit",
    )
    parser.add_argument(
        "--list-voices",
        action="store_true",
        help="List available edge-tts voices and exit",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable debug logging",
    )
    return parser.parse_args()


def list_devices():
    """Print available audio input/output devices."""
    print("\nAudio Devices:")
    print("-" * 60)
    devices = sd.query_devices()
    default_in, default_out = sd.default.device
    for i, d in enumerate(devices):
        marker = ""
        if i == default_in:
            marker += " [DEFAULT INPUT]"
        if i == default_out:
            marker += " [DEFAULT OUTPUT]"
        ins = d["max_input_channels"]
        outs = d["max_output_channels"]
        if ins > 0 or outs > 0:
            print(f"  {i:3d}: {d['name']:<45s} ({ins} in, {outs} out){marker}")
    print()


def list_voices():
    """Print available edge-tts English voices."""
    async def _list():
        import edge_tts

        voices = await edge_tts.list_voices()
        print("\nEdge TTS Voices (English):")
        print("-" * 80)
        for v in voices:
            if v["Locale"].startswith("en-"):
                tags = ", ".join(v.get("VoiceTag", {}).values())
                print(f"  {v['ShortName']:<45s} {v['Gender']:<8s} {tags}")
        print()

    asyncio.run(_list())


def run_bridge(args):
    """Initialise and run the voice bridge from parsed args."""
    from voice_bridge_core import VoiceBridge

    log.info("Initializing voice bridge...")

    stt = create_stt(args.stt)
    tts = create_tts(args.tts, args.tts_voice, args.tts_rate)
    llm = OpenCodeBridge(model=args.model, cwd=args.cwd)

    bridge = VoiceBridge(
        stt=stt,
        tts=tts,
        llm=llm,
        input_device=args.input_device,
        output_device=args.output_device,
    )
    bridge.run()
