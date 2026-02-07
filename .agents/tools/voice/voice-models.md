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
- **Cloud APIs**: ElevenLabs, OpenAI TTS — see official API docs

**When to use**: Voice interfaces, content narration, accessibility, voice cloning, podcast generation, phone bots (with Twilio via `speech-to-speech.md`).

<!-- AI-CONTEXT-END -->

## Text-to-Speech (TTS) Models

### Implemented in This Repo

The voice bridge (`voice-bridge.py`) implements three TTS engines:

#### EdgeTTS (Default)

Microsoft Edge TTS via `edge-tts` package. See `voice-bridge.py:133-179`.

- Free, no API key needed
- 300+ voices across 70+ languages
- Streaming support, adjustable rate
- Default voice: `en-GB-SoniaNeural`

```bash
# Use via voice bridge
voice-helper.sh talk
```

#### macOS Say

Native macOS speech synthesis. See `voice-bridge.py:182-205`.

- Built-in, zero dependencies
- Default voice: `Samantha`
- macOS only

#### FacebookMMS TTS

Meta's Massively Multilingual Speech. See `voice-bridge.py:208-238`.

- 1,100+ languages
- Requires `transformers` package
- CPU-friendly

### Other Local Models (Not Implemented)

These are available but not integrated into the voice bridge:

| Model | Notes | Docs |
|-------|-------|------|
| Qwen3-TTS | Multilingual, voice cloning | https://github.com/QwenLM/Qwen3-TTS |
| Piper TTS | Lightweight, CPU-friendly, 100+ voices | https://github.com/rhasspy/piper |
| Bark (Suno) | Expressive, non-speech sounds | https://github.com/suno-ai/bark |
| Coqui TTS | Multi-model toolkit, voice cloning | https://github.com/coqui-ai/TTS |

### Cloud APIs (Not Implemented)

These require API keys and are not integrated into the voice bridge:

| Provider | Docs |
|----------|------|
| ElevenLabs | https://elevenlabs.io/docs/api-reference/text-to-speech |
| OpenAI TTS | https://platform.openai.com/docs/api-reference/audio/createSpeech |
| Hugging Face Inference | https://huggingface.co/docs/api-inference/tasks/text-to-speech |

## Model Selection Guide

| Priority | Implemented | Not Yet Integrated |
|----------|-------------|-------------------|
| Default (free) | EdgeTTS | — |
| macOS native | macOS Say | — |
| Multilingual | FacebookMMS | Qwen3-TTS |
| Voice clone | — | Qwen3-TTS, ElevenLabs |
| Expressiveness | — | Bark |
| CPU-only | All three | Piper |
| Highest quality | — | ElevenLabs |

## Related

- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD+STT+LLM+TTS)
- `tools/voice/transcription.md` - STT/transcription models
- `voice-helper.sh` - CLI for voice operations
