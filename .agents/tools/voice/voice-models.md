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

## Text-to-Speech (TTS) Models

### Implemented in This Repo

The voice bridge (`voice-bridge.py`) implements three TTS engines:

| Engine | Notes | Code ref |
|--------|-------|----------|
| **EdgeTTS** (default) | Free, 300+ voices/70+ langs, streaming, default `en-GB-SoniaNeural` | `voice-bridge.py:133-179` |
| **macOS Say** | Built-in, zero deps, default `Samantha`, macOS only | `voice-bridge.py:182-205` |
| **FacebookMMS** | 1,100+ languages, requires `transformers`, CPU-friendly | `voice-bridge.py:208-238` |

```bash
voice-helper.sh talk  # Use via voice bridge
```

### Local Open-Weight Models

#### Qwen3-TTS (Recommended for Quality + Multilingual)

Alibaba's open-weight TTS series. 7.1k stars, Apache-2.0. Sizes: 0.6B and 1.7B.

- **Languages**: Chinese, English, Japanese, Korean, German, French, Russian, Portuguese, Spanish, Italian
- **Features**: Voice cloning (3s reference), voice design (text description), 9 built-in speakers, emotion/prosody control, streaming (97ms first-packet)
- **Requires**: CUDA GPU, Python 3.12, PyTorch 2.4+; vLLM day-0 support
- **Install**: `pip install qwen-tts`

```python
from qwen_tts import Qwen3TTSModel
import torch, soundfile as sf

model = Qwen3TTSModel.from_pretrained("Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
    device_map="cuda:0", dtype=torch.bfloat16)
wavs, sr = model.generate_custom_voice(text="Hello, this is a test.",
    language="English", speaker="Ryan")
sf.write("output.wav", wavs[0], sr)
```

Docs: https://github.com/QwenLM/Qwen3-TTS

#### Kokoro (Recommended for Lightweight + Fast)

82M parameter open-weight TTS. 5.6k stars, Apache-2.0.

- **Languages**: American/British English, Spanish, French, Hindi, Italian, Japanese, Brazilian Portuguese, Mandarin
- **Features**: Fast inference, multiple voice presets, MPS (Apple Silicon)
- **Requires**: `espeak-ng`, Python 3.9+ — **Install**: `pip install kokoro`

```python
from kokoro import KPipeline
import soundfile as sf

pipeline = KPipeline(lang_code='a')  # 'a' = American English
for i, (gs, ps, audio) in enumerate(pipeline("Hello world!", voice='af_heart')):
    sf.write(f'{i}.wav', audio, 24000)
```

Docs: https://github.com/hexgrad/kokoro

#### Dia (Recommended for Dialogue)

1.6B parameter dialogue TTS by Nari Labs. 19.1k stars, Apache-2.0. English only (~4.4GB VRAM).

- **Features**: Multi-speaker in one pass (`[S1]`/`[S2]` tags), non-verbal sounds (laughs, coughs, sighs), voice cloning via audio prompt
- **Requires**: CUDA GPU, PyTorch 2.0+ — **Install**: `pip install git+https://github.com/nari-labs/dia.git`
- **Dia2**: https://github.com/nari-labs/dia2

```python
from dia.model import Dia

model = Dia.from_pretrained("nari-labs/Dia-1.6B-0626")
output = model.generate(
    "[S1] Hey, how are you doing? [S2] I'm great, thanks for asking! (laughs)"
)
```

Docs: https://github.com/nari-labs/dia

#### F5-TTS (Recommended for Voice Cloning)

Flow-matching TTS with zero-shot voice cloning. 14.1k stars, MIT (code), CC-BY-NC (weights).

- **Languages**: Chinese, English (base), extensible via fine-tuning
- **Features**: Zero-shot cloning from short reference audio, sway sampling, multi-speaker, Gradio UI, CLI, Docker, TensorRT-LLM
- **Requires**: CUDA/ROCm/XPU/MPS, Python 3.10+ — **Install**: `pip install f5-tts`

```bash
f5-tts_infer-cli \
  --model F5TTS_v1_Base \
  --ref_audio "reference.wav" \
  --ref_text "Transcript of reference audio." \
  --gen_text "Text to generate in the cloned voice."
```

Docs: https://github.com/SWivid/F5-TTS

#### Bark (Suno)

Transformer-based TTS with non-speech generation. 39k+ stars, MIT. **No active development since 2023.**

- **Languages**: 13 languages including English, Chinese, French, German, Hindi, Japanese, Spanish
- **Features**: Non-speech sounds (music, laughter, background noise), speaker presets
- **Install**: `pip install git+https://github.com/suno-ai/bark.git`

Docs: https://github.com/suno-ai/bark

#### Coqui TTS

Multi-model TTS toolkit. 44k+ stars, MPL-2.0. **Company shut down late 2023; community-maintained.**

- **Features**: 20+ models (Tacotron2, VITS, YourTTS, Bark, etc.), voice cloning, multi-speaker, training
- **Install**: `pip install TTS`

Docs: https://github.com/coqui-ai/TTS

#### Piper TTS (Archived)

Fast local neural TTS. 10.5k stars, MIT. **Archived Oct 2025** — active fork: https://github.com/OHF-Voice/piper1-gpl (GPL).

- **Features**: Lightweight C++ binary, 100+ voices, CPU-friendly; best for embedded/IoT, Home Assistant

Docs: https://github.com/rhasspy/piper (archived)

### Cloud TTS APIs

Require API keys. Store via `aidevops secret set <KEY_NAME>`.

| Provider | Quality | Voices | Voice Clone | Streaming | Docs |
|----------|---------|--------|-------------|-----------|------|
| **ElevenLabs** | Highest | 1000+ | Yes (instant) | Yes | https://elevenlabs.io/docs/api-reference/text-to-speech |
| **MiniMax (Hailuo)** | High | Multiple | Yes (10s clip) | Yes | https://www.minimax.io/ |
| **OpenAI TTS** | High | 6 built-in | No | Yes | https://platform.openai.com/docs/api-reference/audio/createSpeech |
| **Google Cloud TTS** | High | 400+ | No | Yes | https://cloud.google.com/text-to-speech/docs |
| **HF Inference** | Varies | Model-dependent | Model-dependent | Some | https://huggingface.co/docs/api-inference/tasks/text-to-speech |

#### ElevenLabs (Highest Quality Cloud)

```bash
curl -X POST "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM" \
  -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello world", "model_id": "eleven_multilingual_v2"}'
```

#### MiniMax / Hailuo (Best Value for Talking-Head Content)

$5/month for 120 minutes. Voice clone from 10s clip. High default quality, less tuning than ElevenLabs. Best for talking-head videos when cost > peak quality.

```bash
curl -X POST "https://api.minimax.chat/v1/t2a_v2" \
  -H "Authorization: Bearer ${MINIMAX_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "speech-02-hd", "text": "Hello world", "voice_setting": {"voice_id": "your-cloned-voice-id"}}'
```

#### OpenAI TTS

Models: `tts-1` (fast), `tts-1-hd` (higher quality). Voices: alloy, echo, fable, onyx, nova, shimmer.

```bash
curl https://api.openai.com/v1/audio/speech \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "tts-1-hd", "input": "Hello world", "voice": "alloy"}'
```

## Speech-to-Text (STT) Models

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

# Local TTS models
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

- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD+STT+LLM+TTS)
- `tools/voice/transcription.md` - STT/transcription models and cloud APIs
- `tools/voice/buzz.md` - Buzz offline transcription GUI
- `content/heygen-skill/rules-voices.md` - AI voice cloning for video
- `voice-helper.sh` - CLI for voice operations
- `voice-bridge.py` - Python voice bridge implementation
