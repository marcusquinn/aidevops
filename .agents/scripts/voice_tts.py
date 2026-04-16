#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Text-to-speech engines for voice-bridge.py.

Extracted from voice-bridge.py to reduce file complexity.

Provides:
  - EdgeTTS: Microsoft Edge TTS (requires internet, excellent quality)
  - MacOSSayTTS: macOS built-in say command (instant, offline)
  - FacebookMMSTTS: Facebook MMS VITS (local, no network, robotic quality)
"""

import asyncio
import logging
import os
import subprocess
import tempfile

import sounddevice as sd

log = logging.getLogger("voice-bridge")


class EdgeTTS:
    """Microsoft Edge TTS - excellent quality, requires internet."""

    def __init__(self, voice="en-GB-SoniaNeural", rate="+20%"):
        import edge_tts  # noqa: F401 - verify import

        self.voice = voice
        self.rate = rate
        self._playback_proc = None
        self._tmp_path = None
        log.info(f"TTS loaded (edge-tts, voice: {voice}, rate: {rate})")

    def speak(self, text):
        """Convert text to speech and play it. Can be interrupted via stop()."""
        if not text or not text.strip():
            return

        async def _generate():
            import edge_tts

            communicate = edge_tts.Communicate(text, self.voice, rate=self.rate)
            with tempfile.NamedTemporaryFile(
                suffix=".mp3", delete=False
            ) as f:
                tmp_path = f.name
            await communicate.save(tmp_path)
            return tmp_path

        self._tmp_path = asyncio.run(_generate())
        try:
            self._playback_proc = subprocess.Popen(
                ["afplay", self._tmp_path],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            self._playback_proc.wait()
        finally:
            self._playback_proc = None
            if self._tmp_path and os.path.exists(self._tmp_path):
                os.unlink(self._tmp_path)
                self._tmp_path = None

    def stop(self):
        """Interrupt playback immediately."""
        if self._playback_proc and self._playback_proc.poll() is None:
            self._playback_proc.terminate()
            log.info("TTS interrupted (barge-in)")


class MacOSSayTTS:
    """macOS built-in say command - instant, no network needed."""

    def __init__(self, voice="Samantha"):
        self.voice = voice
        self._playback_proc = None
        log.info(f"TTS loaded (macOS say, voice: {voice})")

    def speak(self, text):
        if not text or not text.strip():
            return
        self._playback_proc = subprocess.Popen(
            ["say", "-v", self.voice, text],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self._playback_proc.wait()
        self._playback_proc = None

    def stop(self):
        """Interrupt playback immediately."""
        if self._playback_proc and self._playback_proc.poll() is None:
            self._playback_proc.terminate()
            log.info("TTS interrupted (barge-in)")


class FacebookMMSTTS:
    """Facebook MMS VITS - local, no network, robotic quality."""

    def __init__(self):
        import torch
        from transformers import VitsModel, AutoTokenizer

        self.model = VitsModel.from_pretrained("facebook/mms-tts-eng")
        self.tokenizer = AutoTokenizer.from_pretrained("facebook/mms-tts-eng")
        self.sample_rate = self.model.config.sampling_rate
        self._interrupted = False
        log.info("TTS loaded (facebook MMS)")

    def speak(self, text):
        if not text or not text.strip():
            return
        import torch

        self._interrupted = False
        inputs = self.tokenizer(text, return_tensors="pt")
        with torch.no_grad():
            output = self.model(**inputs).waveform
        audio = output.squeeze().numpy()
        sd.play(audio, samplerate=self.sample_rate)
        sd.wait()

    def stop(self):
        """Interrupt playback."""
        self._interrupted = True
        sd.stop()
        log.info("TTS interrupted (barge-in)")
