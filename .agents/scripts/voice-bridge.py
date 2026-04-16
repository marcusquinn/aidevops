#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Voice Bridge for aidevops - Talk to OpenCode via speech.

Architecture:
  Mic → VAD → STT → OpenCode (run/serve) → TTS → Speaker

Swappable components:
  STT: whisper-mlx (default), faster-whisper, macos-dictation
  TTS: edge-tts (default), macos-say, facebookMMS
  LLM: opencode run (default), opencode serve

Usage:
  python voice-bridge.py [--stt whisper-mlx] [--tts edge-tts] [--tts-voice en-US-GuyNeural]

Module layout:
  voice_stt.py         — SileroVAD + STT engines
  voice_tts.py         — TTS engines
  voice_llm.py         — OpenCodeBridge (LLM query)
  voice_bridge_core.py — VoiceBridge main loop
  voice_bridge_cli.py  — CLI parsing, device/voice listing, factory functions
"""

import logging

from voice_bridge_cli import parse_args, list_devices, list_voices, run_bridge

# ─── Logging ──────────────────────────────────────────────────────────

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("voice-bridge")


def main():
    args = parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    if args.list_devices:
        list_devices()
        return

    if args.list_voices:
        list_voices()
        return

    run_bridge(args)


if __name__ == "__main__":
    main()
