---
description: Voice AI model landscape - TTS, STT, and S2S model selection reference
mode: subagent
tools:
  read: true
---

# Voice AI Models

<!-- AI-CONTEXT-START -->

## Quick Reference

- **TTS details**: `tools/voice/voice-models.md` (implemented engines, integration)
- **STT details**: `tools/voice/transcription.md` (transcription workflows, cloud APIs)
- **S2S pipeline**: `tools/voice/speech-to-speech.md` (full voice pipeline)
- **Cloud voice agents**: `tools/voice/cloud-voice-agents.md` (GPT-4o Realtime, MiniCPM-o, Nemotron)
- **Pipecat**: `tools/voice/pipecat-opencode.md` (real-time voice pipeline)
- **Offline tool**: `tools/voice/buzz.md` (Buzz GUI/CLI for Whisper)
- **CLI**: `voice-helper.sh`

## Decision Flow

```text
Need voice AI?
├── Generate speech (TTS)
│   ├── Voice cloning? → Qwen3-TTS (local) or ElevenLabs (cloud)
│   ├── Lowest latency? → Cartesia Sonic 3 (cloud) or EdgeTTS (free)
│   ├── Offline? → Piper (CPU) or Qwen3-TTS (GPU)
│   └── Default → EdgeTTS (free, good quality)
├── Transcribe speech (STT)
│   ├── Real-time? → Deepgram Nova (cloud) or faster-whisper (local)
│   ├── Best accuracy? → ElevenLabs Scribe (cloud) or Large v3 (local)
│   ├── Free? → Groq free tier (cloud) or any local model
│   └── Default → Whisper Large v3 Turbo (local)
└── Conversational (S2S)
    ├── Cloud OK? → GPT-4o Realtime (see cloud-voice-agents.md)
    ├── Enterprise/on-prem? → NVIDIA Riva (Parakeet + LLM + Magpie)
    ├── Local/private? → MiniCPM-o 2.6 or cascaded pipeline
    └── Default → speech-to-speech.md cascaded pipeline
```

<!-- AI-CONTEXT-END -->

## TTS (Text-to-Speech)

### Cloud

| Provider | Latency | Quality | Voice Clone | Languages | Pricing |
|----------|---------|---------|-------------|-----------|---------|
| ElevenLabs | ~300ms | Best | Yes | 29 | $5-330/mo |
| OpenAI TTS | ~400ms | Great | No | 57 | $15/1M chars |
| Cartesia Sonic 3 | ~90ms | Great | Yes (10s ref) | 17 | $8-66/mo |
| NVIDIA Magpie TTS | ~200ms | Great | Yes (zero-shot) | 17+ | NIM API (free tier) |
| Google Cloud TTS | ~200ms | Good | No (custom) | 50+ | $4-16/1M chars |

### Local

| Model | Params | License | Languages | Voice Clone | VRAM | Notes |
|-------|--------|---------|-----------|-------------|------|-------|
| Qwen3-TTS 0.6B | 0.6B | Apache-2.0 | 10 | Yes (5s ref) | 2GB | |
| Qwen3-TTS 1.7B | 1.7B | Apache-2.0 | 10 | Yes (5s ref) | 4GB | |
| Bark (Suno) | 1.0B | MIT | 13+ | Yes (prompt) | 6GB | Expressive (laughter/music); stale |
| Coqui TTS | varies | MPL-2.0 | 20+ | Yes | 2-6GB | |
| Piper | <100M | MIT | 30+ | No | CPU only | |

Also available: EdgeTTS (free, 300+ voices), macOS Say (zero deps), FacebookMMS (1100+ languages). See `voice-models.md`.

## STT (Speech-to-Text)

### Cloud

| Provider | Model | Accuracy | Real-time | Cost |
|----------|-------|----------|-----------|------|
| Groq | Whisper Large v3 Turbo | 9.6 | No (batch) | Free tier |
| ElevenLabs | Scribe v2 | 9.9 | No | Per minute |
| NVIDIA Riva | Parakeet CTC/RNNT | 9.4-9.6 | Yes (streaming) | NIM API (free tier) |
| Deepgram | Nova-2 / Nova-3 | 9.5-9.6 | Yes | Per minute |
| Soniox | stt-async-v3 | 9.6 | Yes | Per minute |

### Local

| Model | Size | Accuracy | Speed | VRAM |
|-------|------|----------|-------|------|
| Whisper Tiny | 75MB | 6.0 | Fastest | 1GB |
| Whisper Base | 142MB | 7.3 | Fast | 1GB |
| Whisper Small | 461MB | 8.5 | Medium | 2GB |
| Whisper Large v3 | 2.9GB | 9.8 | Slow | 10GB |
| Whisper Large v3 Turbo | 1.5GB | 9.7 | Fast | 5GB |
| NVIDIA Parakeet V2 | 0.6B | 9.4 | Fastest | 2GB (English-only) |
| NVIDIA Parakeet V3 | 0.6B | 9.6 | Fastest | 2GB (25 langs) |
| Apple Speech | Built-in | 9.0 | Fast | On-device (macOS 26+) |

Backends: `faster-whisper` (4x speed, recommended), `whisper.cpp` (C++ native, Apple Silicon optimized). See `transcription.md`.

## S2S (Speech-to-Speech)

### Native Models

| Model | Type | Latency | Availability | Notes |
|-------|------|---------|--------------|-------|
| GPT-4o Realtime | Cloud API | ~300ms | OpenAI API (GA) | Emotion-aware, function calling, SIP telephony |
| Gemini 2.0 Live | Cloud API | ~350ms | Google API | Multimodal, streaming |
| MiniCPM-o 2.6 | Open weights | ~500ms | Local (8GB+) | 8B, Apache-2.0, vision+speech+streaming |
| AWS Nova Sonic | Cloud API | ~600ms | AWS API | AWS ecosystem, 7 languages |
| Ultravox | Open weights | ~400ms | Local (6GB+) | Audio-text multimodal |

### NVIDIA Riva Composable Pipelines

| Component | Model | Languages | NIM |
|-----------|-------|-----------|-----|
| ASR | Parakeet TDT 0.6B v2 | English | HF (research) |
| ASR | Parakeet CTC 1.1B | English | Yes |
| ASR | Parakeet RNNT 1.1B | 25 | Yes |
| TTS | Magpie Multilingual | 17+ | Yes |
| TTS | Magpie Zero-Shot | English+ | API |
| Enhancement | StudioVoice | Any | Yes |
| Translation | Riva Translate | 36 | Yes |

Pipeline: `Audio -> [Parakeet ASR] -> [Any LLM] -> [Magpie TTS] -> Audio`. See `cloud-voice-agents.md`. Cascaded S2S (VAD+STT+LLM+TTS): see `speech-to-speech.md`.

## GPU Planning

| Workload | Min VRAM | Recommended VRAM/RAM |
|----------|----------|----------------------|
| STT (Whisper Turbo) | 5GB | 8GB |
| TTS (Qwen3 0.6B) | 2GB | 4GB |
| S2S (MiniCPM-o) | 8GB | 16GB |
| Full cascaded pipeline | 4GB | 12GB |
| CPU-only (Piper + whisper.cpp) | 0 (no GPU) | 8GB RAM |

Apple Silicon: MPS for PyTorch models; `whisper-mlx` or `mlx-audio-whisper` for optimized macOS inference.
