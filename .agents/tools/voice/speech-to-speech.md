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
- **Use for**: Voice interfaces, transcription pipelines, voice-driven DevOps, phone-based AI assistants (pairs with Twilio)

<!-- AI-CONTEXT-END -->

## Architecture

```text
Microphone/Socket -> [VAD] -> [STT] -> [LLM] -> [TTS] -> Speaker/Socket
```

Four-stage cascaded pipeline via thread-safe queues; each stage runs in its own thread.

## Components

### VAD — Silero VAD v5 (default, production-grade)

Key params: `--thresh` (sensitivity), `--min_speech_ms`, `--min_silence_ms`

### STT

| Implementation | Flag | Best For |
|---------------|------|----------|
| Whisper (Transformers) | `--stt whisper` | CUDA, general |
| Faster Whisper | `--stt faster-whisper` | CUDA, lower latency |
| Lightning Whisper MLX | `--stt whisper-mlx` | macOS Apple Silicon |
| MLX Audio Whisper | `--stt mlx-audio-whisper` | macOS, newer models |
| Paraformer (FunASR) | `--stt paraformer` | Chinese, low latency |
| Parakeet TDT | `--stt parakeet-tdt` | CUDA, NVIDIA NeMo |
| Moonshine | `--stt moonshine` | Lightweight |

Model: `--stt_model_name <model>` (any Whisper checkpoint on HF Hub)

### LLM

| Implementation | Flag | Best For |
|---------------|------|----------|
| Transformers | `--llm transformers` | CUDA, any HF model |
| MLX-LM | `--llm mlx-lm` | macOS Apple Silicon |
| OpenAI API | `--llm open_api` | Cloud, lowest latency |

Model: `--lm_model_name <model>` or `--mlx_lm_model_name <model>`

> **Security:** Store `OPENAI_API_KEY` via `aidevops secret set OPENAI_API_KEY`. Never hardcode keys. See `tools/credentials/api-key-setup.md`.

### TTS

| Implementation | Flag | Best For |
|---------------|------|----------|
| Parler-TTS | `--tts parler` | CUDA, streaming |
| MeloTTS | `--tts melo` | Multi-language (6 langs) |
| ChatTTS | `--tts chatTTS` | Natural conversational |
| Kokoro | `--tts kokoro` | macOS default, quality |
| FacebookMMS | `--tts facebookMMS` | 1000+ languages |
| Pocket TTS | `--tts pocket` | Lightweight |
| Qwen3-TTS | `--tts qwen3-tts` | 10 langs, voice cloning, 97ms latency |

## Deployment

GPU sizing: 4GB VRAM minimum, 8–16GB recommended. See `tools/infrastructure/cloud-gpu.md`.

```bash
speech-to-speech-helper.sh start --local-mac   # macOS Apple Silicon (MPS)
speech-to-speech-helper.sh start --cuda        # CUDA GPU (torch compile optimizations)
speech-to-speech-helper.sh start --server      # server/client — run on GPU server
speech-to-speech-helper.sh client --host <ip>  # connect from local machine
speech-to-speech-helper.sh start --docker      # Docker (pytorch 2.4.0-cuda12.1, ports 12345/12346)
```

## Setup

**Requirements:** Python 3.10+, PyTorch 2.4+, `uv`, CUDA 12.1+ or Apple Silicon, `sounddevice`, ~4GB VRAM.

```bash
speech-to-speech-helper.sh setup
# Manual:
git clone https://github.com/huggingface/speech-to-speech.git && cd speech-to-speech
uv pip install -r requirements.txt          # CUDA/Linux
uv pip install -r requirements_mac.txt      # macOS
python -m unidic download                   # MeloTTS only
```

## Multi-Language

```bash
speech-to-speech-helper.sh start --local-mac --language auto   # auto-detect per utterance
speech-to-speech-helper.sh start --local-mac --language zh     # fixed language
```

Requires multilingual STT (e.g., `--stt_model_name large-v3`) and multilingual TTS (MeloTTS or ChatTTS; Parler-TTS is English-only).

## CLI Parameters

All params use prefix convention: `--stt_*`, `--lm_*`, `--tts_*`, `--melo_*`. Generation params use `_gen_` infix: `--stt_gen_max_new_tokens 128`.

Full reference: `python s2s_pipeline.py -h` or [arguments_classes/](https://github.com/huggingface/speech-to-speech/tree/main/arguments_classes)

## Recommended Configurations

| Use Case | Flags |
|----------|-------|
| Low latency (CUDA) | `--stt faster-whisper --llm open_api --tts parler --stt_compile_mode reduce-overhead --tts_compile_mode default` |
| Low VRAM (~4GB) | `--stt moonshine --llm open_api --tts pocket` |
| Best quality (CUDA 24GB+) | `--stt whisper --stt_model_name openai/whisper-large-v3 --llm transformers --lm_model_name microsoft/Phi-3-mini-4k-instruct --tts parler` |
| macOS optimal | `--local_mac_optimal_settings --device mps --mlx_lm_model_name mlx-community/Meta-Llama-3.1-8B-Instruct-4bit` |

## Integrations

- **Transcription**: Standalone — use Whisper directly (`tools/voice/transcription.md`). S2S-based — use `--llm open_api` with a transcription-only system prompt.
- **Phone (Twilio)**: WebSocket audio stream → S2S → TTS response. See `services/communications/twilio.md`.
- **Video narration**: LLM script → TTS audio → Remotion composite. See `tools/video/remotion.md`.
- **Voice-driven DevOps**: STT → LLM (system prompt) → TTS confirm. Integration pattern, not a built-in command.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `Cannot use CUDA on macOS` | Use `--device mps` or `--local_mac_optimal_settings` |
| MeloTTS import error | Run `python -m unidic download` |
| High latency | Enable torch compile: `--stt_compile_mode reduce-overhead` |
| Audio crackling | Increase `--min_silence_ms` or check sample rate |
| OOM on GPU | Use smaller models or `--llm open_api` to offload LLM |

## Voice Bridge (Recommended for Agent Use)

For talking directly to your AI coding agent, use the voice bridge — simpler, faster, integrates with OpenCode:

```bash
voice-helper.sh talk                              # start voice conversation
voice-helper.sh talk whisper-mlx edge-tts         # explicit engines
voice-helper.sh talk whisper-mlx macos-say        # offline mode
voice-helper.sh devices | voices | benchmark
```

**Architecture:** `Mic -> Silero VAD -> Whisper MLX (1.4s) -> OpenCode run --attach (~4-6s) -> Edge TTS (0.4s) -> Speaker`

**Round-trip:** ~6–8s conversational, longer for tool execution. Supports swappable STT/TTS engines, voice exit phrases, STT sanity checking, session handback, Esc interrupt, and graceful TUI degradation.

## See Also

- `tools/voice/cloud-voice-agents.md` — Cloud voice agents (GPT-4o Realtime, MiniCPM-o, NVIDIA Nemotron Speech)
- `tools/voice/voice-ai-models.md` — Complete model comparison (TTS, STT, S2S)
- `tools/voice/pipecat-opencode.md` — Pipecat real-time voice pipeline
- `tools/voice/qwen3-tts.md` — Qwen3-TTS setup, voice cloning, multi-language
- `tools/infrastructure/cloud-gpu.md` — Cloud GPU deployment (provider comparison, setup, cost optimization)
- `services/communications/twilio.md` — Phone integration
- `tools/video/remotion.md` — Video narration
- `content/heygen-skill/rules-voices.md` — AI voice cloning
