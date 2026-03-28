---
description: Voice AI models for speech generation (TTS) and transcription (STT)
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Voice AI Models

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: TTS (text-to-speech) and STT (speech-to-text) model selection and usage
- **Local TTS**: EdgeTTS (default), macOS Say, FacebookMMS — see `voice-bridge.py:133-238`
- **Local STT**: See `tools/voice/transcription.md` for full transcription guide
- **Cloud TTS APIs**: ElevenLabs, OpenAI TTS, Google Cloud TTS, Hugging Face Inference
- **Cloud STT APIs**: Groq Whisper, ElevenLabs Scribe, Deepgram, OpenAI Whisper — see `tools/voice/transcription.md`

**When to use**: Voice interfaces, content narration, accessibility, voice cloning, podcast generation, phone bots (with Twilio via `speech-to-speech.md`), dialogue generation, audiobook creation.

<!-- AI-CONTEXT-END -->

## Chapter Index

| Chapter | Content |
|---------|---------|
| **This file** | Voice bridge engines (EdgeTTS, macOS Say, FacebookMMS), STT summary, selection guides |
| `tools/voice/qwen3-tts.md` | Qwen3-TTS — quality + multilingual, voice cloning, voice design |
| `tools/voice/local-tts-models.md` | Kokoro, Dia, F5-TTS, Bark, Coqui, Piper |
| `tools/voice/cloud-tts-apis.md` | ElevenLabs, MiniMax, OpenAI, Google Cloud, HF Inference |
| `tools/voice/voice-ai-models.md` | High-level TTS/STT/S2S comparison tables and decision flow |
| `tools/voice/transcription.md` | STT models, cloud APIs, transcription pipeline |

## Text-to-Speech (TTS) — Voice Bridge Engines

The voice bridge (`voice-bridge.py`) implements three TTS engines:

| Engine | Notes | Code ref |
|--------|-------|----------|
| **EdgeTTS** (default) | Free, 300+ voices/70+ langs, streaming, default `en-GB-SoniaNeural` | `voice-bridge.py:133-179` |
| **macOS Say** | Built-in, zero deps, default `Samantha`, macOS only | `voice-bridge.py:182-205` |
| **FacebookMMS** | 1,100+ languages, requires `transformers`, CPU-friendly | `voice-bridge.py:208-238` |

```bash
voice-helper.sh talk  # Use via voice bridge
```

## Speech-to-Text (STT) Summary

Full STT coverage (model comparisons, cloud APIs, transcription pipeline): `tools/voice/transcription.md`.

| Category | Recommended | Notes |
|----------|-------------|-------|
| **Local default** | Whisper Large v3 Turbo (1.5GB) | Best speed/accuracy tradeoff |
| **Local fastest** | NVIDIA Parakeet V2 (0.6B) | English-only, speed 9.9 |
| **Local fastest multilingual** | NVIDIA Parakeet V3 (0.6B) | 25 European languages |
| **Local smallest** | Whisper Tiny (75MB) | Draft quality only |
| **Cloud fastest** | Groq Whisper | Free tier, lightning inference |
| **Cloud highest accuracy** | ElevenLabs Scribe v2 | 9.9 accuracy rating |
| **macOS native** | Apple Speech (macOS 26+) | On-device, multilingual |
| **GUI app** | Buzz | Offline, Whisper-based — see `tools/voice/buzz.md` |

Voice bridge (`voice-bridge.py:99-115`) implements `FasterWhisperSTT`. Speech-to-speech pipeline (`speech-to-speech.md`) supports 7 backends: Whisper, Faster Whisper, Lightning Whisper MLX, MLX Audio Whisper, Paraformer, Parakeet TDT, Moonshine.

## Model Selection Guide

### By Use Case

| Use Case | TTS Model | STT Model |
|----------|-----------|-----------|
| **Voice bridge (default)** | EdgeTTS | Whisper MLX (macOS) / Faster Whisper |
| **Podcast/audiobook** | Qwen3-TTS 1.7B or ElevenLabs | — |
| **Dialogue generation** | Dia 1.6B | — |
| **Talking-head video** | MiniMax or ElevenLabs (cloned) | — |
| **Voice cloning** | Qwen3-TTS Base or F5-TTS | — |
| **Voice design (from description)** | Qwen3-TTS VoiceDesign | — |
| **Multilingual (10+ langs)** | Qwen3-TTS or FacebookMMS | Whisper Large v3 |
| **Lightweight/embedded** | Kokoro (82M) or Piper | Whisper Tiny/Base |
| **Highest quality (cloud)** | ElevenLabs | ElevenLabs Scribe v2 |
| **Best value (cloud)** | MiniMax ($5/mo, 120 min) | Groq Whisper |
| **Free cloud** | EdgeTTS | Groq Whisper |
| **Meeting transcription** | — | Whisper Large v3 Turbo or Groq |
| **YouTube transcription** | — | See `transcription.md` pipeline |

### By Resource Constraints

| Constraint | TTS | STT |
|------------|-----|-----|
| **No GPU** | EdgeTTS, macOS Say, Kokoro (CPU), Piper | Whisper.cpp (CPU) |
| **Apple Silicon** | Kokoro (MPS), EdgeTTS | Whisper MLX, Apple Speech |
| **CUDA GPU (4GB+)** | Dia, Kokoro | Faster Whisper |
| **CUDA GPU (8GB+)** | Qwen3-TTS 0.6B, F5-TTS | Whisper Large v3 |
| **CUDA GPU (16GB+)** | Qwen3-TTS 1.7B | — |
| **No API key** | EdgeTTS, macOS Say, all local models | All local models |
| **No internet** | macOS Say, Piper, any downloaded model | Whisper.cpp, Faster Whisper |

## Installation Quick Reference

```bash
# Voice bridge engines
pip install edge-tts transformers

# Local TTS models (see chapter files for details)
pip install qwen-tts kokoro f5-tts TTS
pip install git+https://github.com/nari-labs/dia.git
pip install git+https://github.com/suno-ai/bark.git

# Local STT
pip install faster-whisper
# whisper.cpp: build from source (see transcription.md)

# System dependencies (macOS)
brew install espeak-ng ffmpeg yt-dlp
# Linux: apt install espeak-ng ffmpeg
```

## Related

- `tools/voice/qwen3-tts.md` - Qwen3-TTS (quality + multilingual, voice cloning)
- `tools/voice/local-tts-models.md` - Local open-weight TTS models (Kokoro, Dia, F5-TTS, Bark, Coqui, Piper)
- `tools/voice/cloud-tts-apis.md` - Cloud TTS API reference (ElevenLabs, MiniMax, OpenAI)
- `tools/voice/voice-ai-models.md` - High-level TTS/STT/S2S comparison and decision flow
- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD+STT+LLM+TTS)
- `tools/voice/transcription.md` - STT/transcription models and cloud APIs
- `tools/voice/buzz.md` - Buzz offline transcription GUI
- `content/heygen-skill/rules-voices.md` - AI voice cloning for video
- `voice-helper.sh` - CLI for voice operations
- `voice-bridge.py` - Python voice bridge implementation
