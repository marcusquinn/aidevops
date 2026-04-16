#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Speech-to-text engines and Voice Activity Detection for voice-bridge.py.

Extracted from voice-bridge.py to reduce file complexity.

Provides:
  - SileroVAD: Voice Activity Detection
  - WhisperMLXSTT: Lightning Whisper MLX (fastest on Apple Silicon)
  - FasterWhisperSTT: Faster Whisper (CTranslate2, CPU-optimised)
  - MacOSDictationSTT: macOS built-in (falls back to whisper-mlx)
"""

import logging

import numpy as np

# Audio constants shared with voice-bridge.py
SAMPLE_RATE = 16000

log = logging.getLogger("voice-bridge")


class SileroVAD:
    """Voice Activity Detection using Silero VAD."""

    def __init__(self, threshold=0.5):
        import torch

        self.threshold = threshold
        self.model, self.utils = torch.hub.load(
            "snakers4/silero-vad", "silero_vad", trust_repo=True
        )
        self.model.eval()
        log.info("VAD loaded (Silero)")

    def is_speech(self, audio_chunk_int16):
        """Check if audio chunk contains speech. Expects int16 numpy array."""
        import torch

        audio_float = audio_chunk_int16.astype(np.float32) / 32768.0
        tensor = torch.from_numpy(audio_float)
        confidence = self.model(tensor, SAMPLE_RATE).item()
        return confidence > self.threshold


class WhisperMLXSTT:
    """Lightning Whisper MLX - fastest on Apple Silicon."""

    def __init__(self):
        from lightning_whisper_mlx import LightningWhisperMLX

        self.model = LightningWhisperMLX(
            model="distil-large-v3", batch_size=6, quant=None
        )
        log.info("STT loaded (whisper-mlx distil-large-v3)")

    def transcribe(self, audio_int16):
        """Transcribe int16 audio array to text."""
        audio_float = audio_int16.astype(np.float32) / 32768.0
        result = self.model.transcribe(audio_float)
        text = result.get("text", "").strip()
        return text


class FasterWhisperSTT:
    """Faster Whisper - CTranslate2 backend, CPU optimized."""

    def __init__(self):
        from faster_whisper import WhisperModel

        self.model = WhisperModel(
            "distil-large-v3", device="cpu", compute_type="int8"
        )
        log.info("STT loaded (faster-whisper distil-large-v3)")

    def transcribe(self, audio_int16):
        audio_float = audio_int16.astype(np.float32) / 32768.0
        segments, _ = self.model.transcribe(audio_float, language="en")
        text = " ".join(s.text for s in segments).strip()
        return text


class MacOSDictationSTT:
    """macOS built-in speech recognition (placeholder - uses whisper-mlx)."""

    def __init__(self):
        # macOS SFSpeechRecognizer requires Swift/ObjC bridge
        # Fall back to whisper-mlx for now
        log.warning("macOS dictation not yet implemented, using whisper-mlx")
        self._fallback = WhisperMLXSTT()

    def transcribe(self, audio_int16):
        return self._fallback.transcribe(audio_int16)
