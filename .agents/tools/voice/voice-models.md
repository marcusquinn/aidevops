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
- **Local STT**: See `tools/voice/transcription.md`
- **Cloud TTS APIs**: ElevenLabs, OpenAI TTS, Google Cloud TTS, MiniMax, Hugging Face Inference
- **Cloud STT APIs**: Groq Whisper, ElevenLabs Scribe, Deepgram, OpenAI Whisper — see `tools/voice/transcription.md`

<!-- AI-CONTEXT-END -->

## Text-to-Speech (TTS) Models

### Implemented in This Repo

The voice bridge (`voice-bridge.py`) implements three TTS engines:

#### EdgeTTS (Default)

Microsoft Edge TTS via `edge-tts`. See `voice-bridge.py:133-179`. Free, no API key, 300+ voices/70+ languages, streaming, adjustable rate. Default: `en-GB-SoniaNeural`.

```bash
voice-helper.sh talk
```

#### macOS Say

Native macOS synthesis. See `voice-bridge.py:182-205`. Zero dependencies, default voice `Samantha`, macOS only.

#### FacebookMMS TTS

Meta's Massively Multilingual Speech. See `voice-bridge.py:208-238`. 1,100+ languages, requires `transformers`, CPU-friendly.

### Local Open-Weight Models

| Model | Size | Languages | Key Feature | Install |
|-------|------|-----------|-------------|---------|
| **Qwen3-TTS** | 0.6B / 1.7B | 10 (incl. Chinese, EN, JP) | Voice cloning, voice design, emotion control | `pip install qwen-tts` |
| **Kokoro** | 82M | 9 (EN, ES, FR, HI, IT, JP, PT, ZH) | Lightweight, fast, MPS on Apple Silicon | `pip install kokoro` |
| **Dia** | 1.6B | English only | Multi-speaker dialogue (`[S1]`/`[S2]`), non-verbal sounds | `pip install git+https://github.com/nari-labs/dia.git` |
| **F5-TTS** | — | Chinese, English | Zero-shot voice cloning from short reference audio | `pip install f5-tts` |
| **Bark** | — | 13 languages | Non-speech sounds (music, laughter). No active dev since 2023 | `pip install git+https://github.com/suno-ai/bark.git` |
| **Coqui TTS** | — | Multi | 20+ models (Tacotron2, VITS, YourTTS). Community-maintained | `pip install TTS` |
| **Piper TTS** | — | 100+ voices | Lightweight C++ binary, CPU-friendly. **Archived Oct 2025** → [piper1-gpl](https://github.com/OHF-Voice/piper1-gpl) | — |

**Qwen3-TTS** (recommended for quality + multilingual): CUDA GPU required, Python 3.12, PyTorch 2.4+. Docs: https://github.com/QwenLM/Qwen3-TTS

```python
from qwen_tts import Qwen3TTSModel
import torch, soundfile as sf

model = Qwen3TTSModel.from_pretrained(
    "Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
    device_map="cuda:0", dtype=torch.bfloat16,
)
wavs, sr = model.generate_custom_voice(
    text="Hello, this is a test.", language="English", speaker="Ryan",
)
sf.write("output.wav", wavs[0], sr)
```

**Kokoro** (recommended for lightweight + fast): Requires `espeak-ng`. Docs: https://github.com/hexgrad/kokoro

```python
from kokoro import KPipeline

pipeline = KPipeline(lang_code='a')  # 'a' = American English
generator = pipeline("Hello world!", voice='af_heart')
for i, (gs, ps, audio) in enumerate(generator):
    import soundfile as sf
    sf.write(f'{i}.wav', audio, 24000)
```

**Dia** (recommended for dialogue): CUDA GPU, PyTorch 2.0+. Docs: https://github.com/nari-labs/dia

```python
from dia.model import Dia

model = Dia.from_pretrained("nari-labs/Dia-1.6B-0626")
output = model.generate(
    "[S1] Hey, how are you doing? [S2] I'm great, thanks for asking! (laughs)"
)
```

**F5-TTS** (recommended for voice cloning): CUDA/ROCm/XPU/MPS, Python 3.10+. Docs: https://github.com/SWivid/F5-TTS

```bash
f5-tts_infer-cli \
  --model F5TTS_v1_Base \
  --ref_audio "reference.wav" \
  --ref_text "Transcript of reference audio." \
  --gen_text "Text to generate in the cloned voice."
```

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

$5/month for 120 minutes. Voice clone from 10-second reference clip. High quality out of the box. Access via Higgsfield web UI or direct API.

```bash
curl -X POST "https://api.minimax.chat/v1/t2a_v2" \
  -H "Authorization: Bearer ${MINIMAX_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "speech-02-hd",
    "text": "Hello world",
    "voice_setting": {"voice_id": "your-cloned-voice-id"}
  }'
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

For comprehensive STT coverage including model comparisons, cloud APIs, and the transcription pipeline, see `tools/voice/transcription.md`.

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
# Implemented (voice bridge)
pip install edge-tts                    # EdgeTTS
pip install transformers                # FacebookMMS

# Local TTS models
pip install qwen-tts                    # Qwen3-TTS (CUDA required)
pip install kokoro                      # Kokoro 82M
pip install f5-tts                      # F5-TTS
pip install git+https://github.com/nari-labs/dia.git  # Dia
pip install TTS                         # Coqui TTS
pip install git+https://github.com/suno-ai/bark.git   # Bark

# Local STT models
pip install faster-whisper              # Faster Whisper (recommended)
# whisper.cpp: build from source (see transcription.md)

# System dependencies
brew install espeak-ng                  # Required by Kokoro (macOS)
apt install espeak-ng                   # Required by Kokoro (Linux)
brew install ffmpeg yt-dlp              # Required for transcription pipeline
```

## Related

- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD+STT+LLM+TTS)
- `tools/voice/transcription.md` - STT/transcription models and cloud APIs
- `tools/voice/buzz.md` - Buzz offline transcription GUI
- `tools/video/heygen-skill/rules/voices.md` - AI voice cloning for video
- `voice-helper.sh` - CLI for voice operations
- `voice-bridge.py` - Python voice bridge implementation
