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
- **Cloud voice agents**: `tools/voice/cloud-voice-agents.md` (GPT-4o Realtime, MiniCPM-o, Nemotron)
- **Offline tool**: `tools/voice/buzz.md` (Buzz GUI/CLI for Whisper)

**When to use**: Choosing between voice AI models for a project. For implementation details, follow the cross-references above.

<!-- AI-CONTEXT-END -->

## TTS (Text-to-Speech)

### Cloud Services

| Provider | Latency | Quality | Voice Clone | Languages | Pricing |
|----------|---------|---------|-------------|-----------|---------|
| ElevenLabs | ~300ms | Best | Yes | 29 | $5-330/mo |
| OpenAI TTS | ~400ms | Great | No | 57 | $15/1M chars |
| Cartesia Sonic 3 | ~90ms | Great | Yes (10s ref) | 17 | $8-66/mo |
| NVIDIA Magpie TTS | ~200ms | Great | Yes (zero-shot) | 17+ | NIM API (free tier) |
| Google Cloud TTS | ~200ms | Good | No (custom) | 50+ | $4-16/1M chars |

**Pick**: ElevenLabs for quality/cloning, Cartesia Sonic 3 for lowest latency, NVIDIA Magpie for enterprise/self-hosted, Google for language breadth.

### Local Models

| Model | Params | License | Languages | Voice Clone | GPU VRAM |
|-------|--------|---------|-----------|-------------|----------|
| Qwen3-TTS 0.6B | 0.6B | Apache-2.0 | 10 | Yes (5s ref) | 2GB |
| Qwen3-TTS 1.7B | 1.7B | Apache-2.0 | 10 | Yes (5s ref) | 4GB |
| Bark (Suno) | 1.0B | MIT | 13+ | Yes (prompt) | 6GB (stale) |
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
| NVIDIA Riva | Parakeet CTC/RNNT | 9.4-9.6 | Yes (streaming) | NIM API (free tier) |
| Deepgram | Nova-2 / Nova-3 | 9.5-9.6 | Yes | Per minute |
| Soniox | stt-async-v3 | 9.6 | Yes | Per minute |

**Pick**: Groq for free/fast batch, ElevenLabs Scribe for accuracy, NVIDIA Parakeet for enterprise/self-hosted, Deepgram for real-time streaming.

### Local Models

| Model | Size | Accuracy | Speed | GPU VRAM |
|-------|------|----------|-------|----------|
| Whisper Tiny | 75MB | 6.0 | Fastest | 1GB |
| Whisper Base | 142MB | 7.3 | Fast | 1GB |
| Whisper Small | 461MB | 8.5 | Medium | 2GB |
| Whisper Large v3 | 2.9GB | 9.8 | Slow | 10GB |
| Whisper Large v3 Turbo | 1.5GB | 9.7 | Fast | 5GB |
| NVIDIA Parakeet V2 | 0.6B | 9.4 | Fastest | 2GB |
| NVIDIA Parakeet V3 | 0.6B | 9.6 | Fastest | 2GB |
| Apple Speech | Built-in | 9.0 | Fast | On-device |

**Pick**: Large v3 Turbo as default (best balance), Parakeet V3 for multilingual speed (25 languages), Parakeet V2 for English-only, Apple Speech for zero-setup macOS 26+.

Backends: `faster-whisper` (4x speed, recommended), `whisper.cpp` (C++ native, Apple Silicon optimized). See `transcription.md`.

## S2S (Speech-to-Speech)

### Native S2S Models

End-to-end models that process speech directly without text intermediary:

| Model | Type | Latency | Availability | Notes |
|-------|------|---------|--------------|-------|
| GPT-4o Realtime | Cloud API | ~300ms | OpenAI API (GA) | Voice mode, emotion-aware, function calling, SIP telephony |
| Gemini 2.0 Live | Cloud API | ~350ms | Google API | Multimodal, streaming |
| MiniCPM-o 2.6 | Open weights | ~500ms | Local (8GB+) | 8B params, Apache-2.0, vision+speech+streaming |
| AWS Nova Sonic | Cloud API | ~600ms | AWS API | AWS ecosystem, 7 languages |
| Ultravox | Open weights | ~400ms | Local (6GB+) | Audio-text multimodal |

### Composable S2S Pipelines (NVIDIA Nemotron Speech)

Enterprise-grade cascaded pipelines using NVIDIA Riva NIM microservices:

| Component | Model | Role | Languages | NIM Available |
|-----------|-------|------|-----------|---------------|
| ASR | Parakeet TDT 0.6B v2 | Speech-to-text | English | HF (research) |
| ASR | Parakeet CTC 1.1B | Speech-to-text | English | Yes |
| ASR | Parakeet RNNT 1.1B | Speech-to-text | 25 languages | Yes |
| TTS | Magpie TTS Multilingual | Text-to-speech | 17+ languages | Yes |
| TTS | Magpie TTS Zero-Shot | Voice cloning TTS | English+ | API |
| Enhancement | StudioVoice | Noise removal | Any | Yes |
| Translation | Riva Translate | NMT | 36 languages | Yes |

Compose as: `Audio -> [Parakeet ASR] -> [Any LLM] -> [Magpie TTS] -> Audio`. See `cloud-voice-agents.md` for deployment patterns.

**Pick**: GPT-4o Realtime for production cloud (lowest latency, GA), MiniCPM-o 2.6 for self-hosted/private (Apache-2.0, multimodal), NVIDIA Riva for enterprise on-prem (composable, 25+ languages). For cascaded S2S (VAD+STT+LLM+TTS), see `speech-to-speech.md`.

## Model Selection Guide

### By Priority

| Priority | TTS | STT | S2S |
|----------|-----|-----|-----|
| **Quality** | ElevenLabs / Qwen3-TTS 1.7B | ElevenLabs Scribe / Large v3 | GPT-4o Realtime |
| **Speed** | Cartesia Sonic 3 / EdgeTTS | Groq / Parakeet V3 | GPT-4o Realtime / Cascaded |
| **Cost** | EdgeTTS (free) / Piper | Local Whisper ($0) / Groq free | MiniCPM-o 2.6 (local) |
| **Privacy** | Piper / Qwen3-TTS | faster-whisper / whisper.cpp | MiniCPM-o 2.6 |
| **Enterprise** | NVIDIA Magpie / ElevenLabs | NVIDIA Parakeet / Scribe | NVIDIA Riva pipeline |
| **Voice clone** | ElevenLabs / Qwen3-TTS | N/A | MiniCPM-o 2.6 |

### Decision Flow

```text
Need voice AI?
├── Generate speech (TTS)
│   ├── Need voice cloning? → Qwen3-TTS (local) or ElevenLabs (cloud)
│   ├── Need lowest latency? → Cartesia Sonic 3 (cloud) or EdgeTTS (free)
│   ├── Need offline? → Piper (CPU) or Qwen3-TTS (GPU)
│   └── Default → EdgeTTS (free, good quality)
├── Transcribe speech (STT)
│   ├── Need real-time? → Deepgram Nova (cloud) or faster-whisper (local)
│   ├── Need best accuracy? → ElevenLabs Scribe (cloud) or Large v3 (local)
│   ├── Need free? → Groq free tier (cloud) or any local model
│   └── Default → Whisper Large v3 Turbo (local)
└── Conversational (S2S)
    ├── Cloud OK? → GPT-4o Realtime (see cloud-voice-agents.md)
    ├── Enterprise/on-prem? → NVIDIA Riva (Parakeet + LLM + Magpie)
    ├── Local/private? → MiniCPM-o 2.6 or cascaded pipeline
    └── Default → speech-to-speech.md cascaded pipeline
```

## GPU Requirements Summary

| Use Case | Min VRAM | Recommended |
|----------|----------|-------------|
| STT only (Whisper Turbo) | 5GB | 8GB |
| TTS only (Qwen3-TTS 0.6B) | 2GB | 4GB |
| TTS only (Bark) | 6GB | 8GB |
| S2S (MiniCPM-o 2.6) | 8GB | 16GB |
| Full cascaded pipeline | 4GB | 12GB |
| CPU-only (Piper + whisper.cpp) | 0 | 8GB RAM |

Apple Silicon: MPS acceleration works for most PyTorch models. Use `whisper-mlx` or `mlx-audio-whisper` for optimized macOS inference.

## Related

- `tools/voice/cloud-voice-agents.md` - Cloud voice agent deployment (GPT-4o Realtime, MiniCPM-o, Nemotron)
- `tools/voice/voice-models.md` - TTS engines implemented in voice bridge
- `tools/voice/transcription.md` - STT workflows, cloud API examples
- `tools/voice/speech-to-speech.md` - Full cascaded voice pipeline
- `tools/voice/pipecat-opencode.md` - Pipecat real-time voice pipeline
- `tools/voice/buzz.md` - Buzz offline transcription tool
- `voice-helper.sh` - CLI for voice operations
