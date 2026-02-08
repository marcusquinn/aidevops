---
description: Voice AI model landscape - TTS, STT, and S2S model selection reference
mode: subagent
tools:
  read: true
  bash: true
---

# Voice AI Models

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Comprehensive reference for voice AI model selection across TTS, STT, and S2S
- **TTS details**: `tools/voice/voice-models.md` (implemented engines, integration)
- **STT details**: `tools/voice/transcription.md` (transcription workflows, cloud APIs)
- **S2S pipeline**: `tools/voice/speech-to-speech.md` (full voice pipeline setup)
- **Offline tool**: `tools/voice/buzz.md` (Buzz GUI/CLI for Whisper)

**When to use**: Choosing between voice AI models for a project. For implementation details, follow the cross-references above.

<!-- AI-CONTEXT-END -->

## TTS (Text-to-Speech)

### Cloud Services

| Provider | Latency | Quality | Voice Clone | Languages | Pricing |
|----------|---------|---------|-------------|-----------|---------|
| ElevenLabs | ~300ms | Best | Yes | 29 | $5-330/mo |
| OpenAI TTS | ~400ms | Great | No | 57 | $15/1M chars |
| Cartesia Sonic | ~150ms | Great | Yes (5s ref) | 17 | $8-66/mo |
| Google Cloud TTS | ~200ms | Good | No (custom) | 50+ | $4-16/1M chars |

**Pick**: ElevenLabs for quality/cloning, Cartesia for lowest latency, Google for language breadth.

### Local Models

| Model | Params | License | Languages | Voice Clone | GPU VRAM |
|-------|--------|---------|-----------|-------------|----------|
| Qwen3-TTS 0.6B | 0.6B | Apache-2.0 | 10 | Yes (5s ref) | 2GB |
| Qwen3-TTS 1.7B | 1.7B | Apache-2.0 | 10 | Yes (5s ref) | 4GB |
| Bark (Suno) | 1.0B | MIT | 13+ | Yes (prompt) | 6GB |
| Coqui TTS | varies | MPL-2.0 | 20+ | Yes | 2-6GB |
| Piper | <100M | MIT | 30+ | No | CPU only |

**Pick**: Qwen3-TTS for quality + cloning, Piper for CPU-only/embedded, Bark for expressiveness (laughter, music).

Also implemented in the voice bridge: **EdgeTTS** (free, 300+ voices), **macOS Say** (zero deps), **FacebookMMS** (1100+ languages). See `voice-models.md` for details.

## STT (Speech-to-Text)

### Cloud APIs

| Provider | Model | Accuracy | Real-time | Cost |
|----------|-------|----------|-----------|------|
| Groq | Whisper Large v3 Turbo | 9.6 | No (batch) | Free tier |
| ElevenLabs | Scribe v2 | 9.9 | No | Per minute |
| Deepgram | Nova-2 / Nova-3 | 9.5-9.6 | Yes | Per minute |
| Soniox | stt-async-v3 | 9.6 | Yes | Per minute |

**Pick**: Groq for free/fast batch, ElevenLabs Scribe for accuracy, Deepgram for real-time streaming.

### Local Models

| Model | Size | Accuracy | Speed | GPU VRAM |
|-------|------|----------|-------|----------|
| Whisper Tiny | 75MB | 6.0 | Fastest | 1GB |
| Whisper Base | 142MB | 7.3 | Fast | 1GB |
| Whisper Small | 461MB | 8.5 | Medium | 2GB |
| Whisper Large v3 | 2.9GB | 9.8 | Slow | 10GB |
| Whisper Large v3 Turbo | 1.5GB | 9.7 | Fast | 5GB |
| NVIDIA Parakeet V2 | 474MB | 9.4 | Fastest | 2GB |
| Apple Speech | Built-in | 9.0 | Fast | On-device |

**Pick**: Large v3 Turbo as default (best balance), Parakeet for English-only speed, Apple Speech for zero-setup macOS 26+.

Backends: `faster-whisper` (4x speed, recommended), `whisper.cpp` (C++ native, Apple Silicon optimized). See `transcription.md`.

## S2S (Speech-to-Speech)

End-to-end models that process speech directly without text intermediary:

| Model | Type | Latency | Availability | Notes |
|-------|------|---------|--------------|-------|
| GPT-4o Realtime | Cloud API | ~300ms | OpenAI API | Voice mode, emotion-aware |
| Gemini 2.0 Live | Cloud API | ~350ms | Google API | Multimodal, streaming |
| MiniCPM-o | Open weights | ~500ms | Local (8GB+) | 8B params, Apache-2.0 |
| Ultravox | Open weights | ~400ms | Local (6GB+) | Audio-text multimodal |

**Pick**: GPT-4o Realtime for production cloud, MiniCPM-o for local/private. For cascaded S2S (VAD+STT+LLM+TTS), see `speech-to-speech.md`.

## Model Selection Guide

### By Priority

| Priority | TTS | STT | S2S |
|----------|-----|-----|-----|
| **Quality** | ElevenLabs / Qwen3-TTS 1.7B | ElevenLabs Scribe / Large v3 | GPT-4o Realtime |
| **Speed** | Cartesia / EdgeTTS | Groq / Parakeet | Cascaded pipeline |
| **Cost** | EdgeTTS (free) / Piper | Local Whisper ($0) / Groq free | MiniCPM-o (local) |
| **Privacy** | Piper / Qwen3-TTS | faster-whisper / whisper.cpp | MiniCPM-o |
| **Voice clone** | ElevenLabs / Qwen3-TTS | N/A | N/A |

### Decision Flow

```text
Need voice AI?
├── Generate speech (TTS)
│   ├── Need voice cloning? → Qwen3-TTS (local) or ElevenLabs (cloud)
│   ├── Need lowest latency? → Cartesia (cloud) or EdgeTTS (free)
│   ├── Need offline? → Piper (CPU) or Qwen3-TTS (GPU)
│   └── Default → EdgeTTS (free, good quality)
├── Transcribe speech (STT)
│   ├── Need real-time? → Deepgram Nova (cloud) or faster-whisper (local)
│   ├── Need best accuracy? → ElevenLabs Scribe (cloud) or Large v3 (local)
│   ├── Need free? → Groq free tier (cloud) or any local model
│   └── Default → Whisper Large v3 Turbo (local)
└── Conversational (S2S)
    ├── Cloud OK? → GPT-4o Realtime
    ├── Local/private? → MiniCPM-o or cascaded pipeline
    └── Default → speech-to-speech.md cascaded pipeline
```

## GPU Requirements Summary

| Use Case | Min VRAM | Recommended |
|----------|----------|-------------|
| STT only (Whisper Turbo) | 5GB | 8GB |
| TTS only (Qwen3-TTS 0.6B) | 2GB | 4GB |
| TTS only (Bark) | 6GB | 8GB |
| S2S (MiniCPM-o) | 8GB | 16GB |
| Full cascaded pipeline | 4GB | 12GB |
| CPU-only (Piper + whisper.cpp) | 0 | 8GB RAM |

Apple Silicon: MPS acceleration works for most PyTorch models. Use `whisper-mlx` or `mlx-audio-whisper` for optimized macOS inference.

## Related

- `tools/voice/voice-models.md` - TTS engines implemented in voice bridge
- `tools/voice/transcription.md` - STT workflows, cloud API examples
- `tools/voice/speech-to-speech.md` - Full cascaded voice pipeline
- `tools/voice/buzz.md` - Buzz offline transcription tool
- `voice-helper.sh` - CLI for voice operations
