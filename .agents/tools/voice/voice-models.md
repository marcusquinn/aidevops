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
- **Local TTS**: Qwen3-TTS (recommended), Bark, Coqui TTS, Piper
- **Local STT**: See `tools/voice/transcription.md` for full transcription guide
- **Cloud APIs**: ElevenLabs, OpenAI TTS/Whisper, Hugging Face Inference API

**When to use**: Voice interfaces, content narration, accessibility, voice cloning, podcast generation, phone bots (with Twilio via `speech-to-speech.md`).

<!-- AI-CONTEXT-END -->

## Text-to-Speech (TTS) Models

### Local Models

#### Qwen3-TTS (Recommended)

Open-source, multilingual, voice clone/design support.

| Variant | Size | Languages | Features |
|---------|------|-----------|----------|
| Qwen3-TTS-0.6B | 0.6B | 10 | Voice clone, voice design, streaming |
| Qwen3-TTS-1.7B | 1.7B | 10 | Higher quality, same features |

```bash
# Install
pip install qwen-tts

# Basic generation
python -c "
from qwen_tts import QwenTTS
tts = QwenTTS('Qwen/Qwen3-TTS-0.6B')
tts.synthesize('Hello world', output='output.wav')
"

# Voice cloning (provide reference audio)
python -c "
from qwen_tts import QwenTTS
tts = QwenTTS('Qwen/Qwen3-TTS-0.6B')
tts.synthesize('Hello world', reference_audio='voice.wav', output='cloned.wav')
"

# Streaming with vLLM
vllm serve Qwen/Qwen3-TTS-0.6B --task generate
```

- **Repo**: https://github.com/QwenLM/Qwen3-TTS
- **License**: Apache-2.0
- **Languages**: English, Chinese, Japanese, Korean, French, German, Spanish, Italian, Portuguese, Russian
- **GPU**: 2GB+ VRAM (0.6B), 4GB+ (1.7B)

#### Piper TTS

Lightweight, CPU-friendly, many voices.

```bash
# Install
pip install piper-tts

# Generate speech
echo "Hello world" | piper --model en_US-lessac-medium --output_file output.wav
```

- Fast inference on CPU (Raspberry Pi capable)
- 30+ languages, 100+ voices
- ONNX runtime, no GPU needed

#### Bark (Suno)

Expressive, supports non-speech sounds (laughter, music).

```bash
pip install git+https://github.com/suno-ai/bark.git
python -c "
from bark import SAMPLE_RATE, generate_audio, preload_models
preload_models()
audio = generate_audio('Hello! [laughs] How are you?')
"
```

- 13 languages
- Non-speech tokens: `[laughs]`, `[sighs]`, `[music]`, `[gasps]`
- GPU recommended (4GB+ VRAM)

#### Coqui TTS

Multi-model toolkit with voice cloning.

```bash
pip install TTS
tts --text "Hello world" --model_name tts_models/en/ljspeech/tacotron2-DDC --out_path output.wav
tts --list_models  # Show all available models
```

### Cloud APIs

#### ElevenLabs (Highest Quality)

```bash
# Via helper script
voice-helper.sh tts "Hello world" --provider elevenlabs --voice "Rachel"

# Direct API
curl -X POST "https://api.elevenlabs.io/v1/text-to-speech/{voice_id}" \
  -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello world", "model_id": "eleven_multilingual_v2"}' \
  --output output.mp3
```

- 29+ languages, voice cloning, voice design
- Models: `eleven_multilingual_v2`, `eleven_turbo_v2` (low latency)
- Free tier: 10k characters/month

#### OpenAI TTS

```bash
curl https://api.openai.com/v1/audio/speech \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "tts-1", "input": "Hello world", "voice": "alloy"}' \
  --output output.mp3
```

- Voices: alloy, echo, fable, onyx, nova, shimmer
- Models: `tts-1` (fast), `tts-1-hd` (quality)

#### Hugging Face Inference API

```bash
curl https://api-inference.huggingface.co/models/facebook/mms-tts-eng \
  -H "Authorization: Bearer ${HF_TOKEN}" \
  -d '{"inputs": "Hello world"}' \
  --output output.flac
```

## Model Selection Guide

| Priority | Local | Cloud |
|----------|-------|-------|
| Quality | Qwen3-TTS-1.7B | ElevenLabs |
| Speed | Piper | OpenAI tts-1 |
| Voice clone | Qwen3-TTS | ElevenLabs |
| Expressiveness | Bark | ElevenLabs |
| CPU-only | Piper | N/A |
| Free | All local | HF Inference (limited) |

## Related

- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD+STT+LLM+TTS)
- `tools/voice/transcription.md` - STT/transcription models
- `voice-helper.sh` - CLI for voice operations
