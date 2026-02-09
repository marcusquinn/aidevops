---
description: "HuggingFace Speech-to-Speech - modular voice pipeline (VAD, STT, LLM, TTS) for local GPU and cloud GPU deployment"
mode: subagent
upstream_url: https://github.com/huggingface/speech-to-speech
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

# Speech-to-Speech Pipeline

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Source**: [huggingface/speech-to-speech](https://github.com/huggingface/speech-to-speech) (Apache-2.0)
- **Purpose**: Modular, open-source GPT-4o-style voice assistant pipeline
- **Pipeline**: VAD -> STT -> LLM -> TTS (each component swappable)
- **Helper**: `speech-to-speech-helper.sh [setup|start|stop|status|client|config|benchmark] [options]`
- **Install dir**: `~/.aidevops/.agent-workspace/work/speech-to-speech/`
- **Languages**: English, French, Spanish, Chinese, Japanese, Korean (auto-detect or fixed)

**When to Use**: Read this when setting up voice interfaces, transcription pipelines, voice-driven DevOps, or phone-based AI assistants (pairs with Twilio).

<!-- AI-CONTEXT-END -->

## Architecture

Four-stage cascaded pipeline connected via thread-safe queues:

```text
Microphone/Socket -> [VAD] -> [STT] -> [LLM] -> [TTS] -> Speaker/Socket
                      |         |        |         |
                   Silero    Whisper   Any HF    Parler
                   VAD v5    variants  instruct  Melo
                             Parafor.  OpenAI    ChatTTS
                             Faster-W  MLX-LM    Kokoro
                             Parakeet            FacebookMMS
                             Moonshine           Pocket
```

Each stage runs in its own thread. Audio streams via socket (server/client) or local audio device.

## Component Options

### VAD (Voice Activity Detection)

| Implementation | Notes |
|---------------|-------|
| Silero VAD v5 | Default, production-grade |

Key parameters: `--thresh` (trigger sensitivity), `--min_speech_ms`, `--min_silence_ms`

### STT (Speech to Text)

| Implementation | Flag | Best For |
|---------------|------|----------|
| Whisper (Transformers) | `--stt whisper` | CUDA, general purpose |
| Faster Whisper | `--stt faster-whisper` | CUDA, lower latency |
| Lightning Whisper MLX | `--stt whisper-mlx` | macOS Apple Silicon |
| MLX Audio Whisper | `--stt mlx-audio-whisper` | macOS, newer models |
| Paraformer (FunASR) | `--stt paraformer` | Chinese, low latency |
| Parakeet TDT | `--stt parakeet-tdt` | CUDA, NVIDIA NeMo |
| Moonshine | `--stt moonshine` | Lightweight |

Model selection: `--stt_model_name <model>` (any Whisper checkpoint on HF Hub)

### LLM (Language Model)

| Implementation | Flag | Best For |
|---------------|------|----------|
| Transformers | `--llm transformers` | CUDA, any HF model |
| MLX-LM | `--llm mlx-lm` | macOS Apple Silicon |
| OpenAI API | `--llm open_api` | Cloud, lowest latency |

Model selection: `--lm_model_name <model>` or `--mlx_lm_model_name <model>`

API keys: Store `OPENAI_API_KEY` via `aidevops secret set OPENAI_API_KEY` (gopass encrypted) or in `~/.config/aidevops/credentials.sh` (600 permissions). See `tools/credentials/api-key-setup.md`.

### TTS (Text to Speech)

| Implementation | Flag | Best For |
|---------------|------|----------|
| Parler-TTS | `--tts parler` | CUDA, streaming output |
| MeloTTS | `--tts melo` | Multi-language (6 langs) |
| ChatTTS | `--tts chatTTS` | Natural conversational |
| Kokoro | `--tts kokoro` | macOS default, quality |
| FacebookMMS | `--tts facebookMMS` | 1000+ languages |
| Pocket TTS | `--tts pocket` | Lightweight |

## Deployment Modes

### Local (macOS with Apple Silicon)

Optimal for development and personal use. Uses MPS acceleration:

```bash
# One-liner with optimal Mac settings
speech-to-speech-helper.sh start --local-mac

# Equivalent to:
python s2s_pipeline.py \
    --local_mac_optimal_settings \
    --device mps \
    --stt parakeet-tdt \
    --llm mlx-lm \
    --tts kokoro \
    --mlx_lm_model_name mlx-community/Meta-Llama-3.1-8B-Instruct-4bit
```

### Local (CUDA GPU)

For workstations with NVIDIA GPU:

```bash
# Start with torch compile optimizations
speech-to-speech-helper.sh start --cuda

# Equivalent to:
python s2s_pipeline.py \
    --recv_host 0.0.0.0 --send_host 0.0.0.0 \
    --lm_model_name microsoft/Phi-3-mini-4k-instruct \
    --stt_compile_mode reduce-overhead \
    --tts_compile_mode default
```

### Server/Client (Remote GPU)

For cloud GPU instances (NVIDIA Cloud, Vast.ai, RunPod, Lambda):

```bash
# On GPU server
speech-to-speech-helper.sh start --server

# On local machine (audio I/O)
speech-to-speech-helper.sh client --host <server-ip>

# Or directly:
python listen_and_play.py --host <server-ip>
```

### Docker (CUDA)

```bash
# Start with docker compose
speech-to-speech-helper.sh start --docker

# Uses: pytorch/pytorch:2.4.0-cuda12.1-cudnn9-devel
# Ports: 12345 (recv), 12346 (send)
# GPU: nvidia device 0
```

## Setup

```bash
# Install via helper (clones repo, installs deps)
speech-to-speech-helper.sh setup

# Or manually:
git clone https://github.com/huggingface/speech-to-speech.git
cd speech-to-speech

# CUDA/Linux
uv pip install -r requirements.txt

# macOS
uv pip install -r requirements_mac.txt

# For MeloTTS (optional)
python -m unidic download
```

### Requirements

- Python 3.10+
- PyTorch 2.4+ (CUDA and macOS)
- `uv` package manager (recommended)
- CUDA 12.1+ (for GPU) or Apple Silicon (for MPS)
- `sounddevice` for local audio I/O
- ~4GB VRAM minimum (varies by model selection)

## Multi-Language

```bash
# Auto-detect language per utterance
speech-to-speech-helper.sh start --local-mac --language auto

# Fixed language (e.g., Chinese)
speech-to-speech-helper.sh start --local-mac --language zh
```

Requires compatible STT model (e.g., `--stt_model_name large-v3`) and multilingual TTS (MeloTTS or ChatTTS - Parler-TTS is English-only currently).

## CLI Parameters

All parameters use prefix convention: `--stt_*`, `--lm_*`, `--tts_*`, `--melo_*`, etc.

Generation parameters use `_gen_` infix: `--stt_gen_max_new_tokens 128`

Full reference: `python s2s_pipeline.py -h` or see [arguments_classes/](https://github.com/huggingface/speech-to-speech/tree/main/arguments_classes)

## Integration with aidevops

### Voice-Driven DevOps (Conceptual)

The pipeline can be paired with the LLM stage to create voice-controlled DevOps. This is an integration pattern, not a built-in command:

1. STT captures voice command
2. LLM interprets as DevOps action (via system prompt)
3. TTS confirms action and reports result

For a ready-to-use voice interface, see the Voice Bridge section below.

### Transcription

For standalone transcription (meeting notes, podcasts), use Whisper directly instead of the full S2S pipeline. See `tools/voice/transcription.md` for model options and cloud APIs.

To use the S2S pipeline for transcription, run with `--llm open_api` and a system prompt that outputs transcription only, or use the STT components directly via Python.

### Phone Integration (Twilio)

Combine with `services/communications/twilio.md` for phone-based AI:

1. Twilio receives call, streams audio via WebSocket
2. S2S pipeline processes speech in real-time
3. TTS response streamed back to caller

### Video Narration

Pair with `tools/video/remotion.md` for generated voiceover:

1. Generate script with LLM
2. TTS produces audio track
3. Remotion composites with video

## Cloud GPU Providers

For server/client deployment when local GPU is insufficient, see the shared **[Cloud GPU Deployment Guide](../infrastructure/cloud-gpu.md)** for:

- Provider comparison (RunPod, Vast.ai, Lambda, NVIDIA Cloud)
- GPU selection by VRAM requirements
- SSH setup, Docker deployment, model caching
- Cost optimization strategies

Quick reference for voice pipeline GPU needs: 4GB VRAM minimum (low-VRAM config), 8-16GB recommended (full S2S pipeline). See the guide's VRAM requirements table for details.

## Recommended Configurations

### Low Latency (CUDA)

```bash
--stt faster-whisper --llm open_api --tts parler \
--stt_compile_mode reduce-overhead --tts_compile_mode default
```

### Low VRAM (~4GB)

```bash
--stt moonshine --llm open_api --tts pocket
```

### Best Quality (CUDA, 24GB+)

```bash
--stt whisper --stt_model_name openai/whisper-large-v3 \
--llm transformers --lm_model_name microsoft/Phi-3-mini-4k-instruct \
--tts parler
```

### macOS Optimal

```bash
--local_mac_optimal_settings --device mps \
--mlx_lm_model_name mlx-community/Meta-Llama-3.1-8B-Instruct-4bit
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Cannot use CUDA on macOS` | Use `--device mps` or `--local_mac_optimal_settings` |
| MeloTTS import error | Run `python -m unidic download` |
| High latency | Enable torch compile: `--stt_compile_mode reduce-overhead` |
| Audio crackling | Increase `--min_silence_ms` or check sample rate |
| OOM on GPU | Use smaller models or `--llm open_api` to offload LLM |

## Voice Bridge (Recommended)

For talking directly to your AI coding agent, use the **voice bridge** instead of the full S2S pipeline. It's simpler, faster to start, and integrates with OpenCode:

```bash
voice-helper.sh talk              # Start voice conversation (defaults)
voice-helper.sh talk whisper-mlx edge-tts  # Explicit engines
voice-helper.sh talk whisper-mlx macos-say # Offline mode
voice-helper.sh devices           # List audio devices
voice-helper.sh voices            # List available TTS voices
voice-helper.sh benchmark         # Test component speeds
```

**Architecture:** `Mic -> Silero VAD -> Whisper MLX (1.4s) -> OpenCode run --attach (~4-6s) -> Edge TTS (0.4s) -> Speaker`

**Round-trip:** ~6-8s conversational, longer for tool execution.

**Features:**
- Swappable STT (whisper-mlx, faster-whisper) and TTS (edge-tts, macos-say, facebookMMS)
- Voice exit phrases ("that's all", "goodbye", "all for now")
- STT sanity checking (corrects transcription errors before acting)
- Session handback (transcript output on exit for calling agent)
- Esc key interrupt in terminal, graceful degradation in TUI subprocess

The full S2S pipeline above is for advanced use cases (custom LLMs, server/client deployment, multi-language, phone integration).

## See Also

- `tools/voice/cloud-voice-agents.md` - Cloud voice agents (GPT-4o Realtime, MiniCPM-o, NVIDIA Nemotron Speech)
- `tools/voice/voice-ai-models.md` - Complete model comparison (TTS, STT, S2S)
- `tools/voice/pipecat-opencode.md` - Pipecat real-time voice pipeline
- `tools/infrastructure/cloud-gpu.md` - Cloud GPU deployment guide (provider comparison, setup, cost optimization)
- `services/communications/twilio.md` - Phone integration
- `tools/video/remotion.md` - Video narration
- `tools/video/heygen-skill/rules/voices.md` - AI voice cloning
