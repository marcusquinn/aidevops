---
description: Cloud TTS API reference - ElevenLabs, MiniMax, OpenAI, Google Cloud, HF Inference
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

# Cloud TTS APIs

API keys required. Store via `aidevops secret set <KEY_NAME>`.

## Provider Comparison

| Provider | Quality | Voices | Voice Clone | Streaming | Docs |
|----------|---------|--------|-------------|-----------|------|
| **ElevenLabs** | Highest | 1000+ | Yes (instant) | Yes | https://elevenlabs.io/docs/api-reference/text-to-speech |
| **MiniMax (Hailuo)** | High | Multiple | Yes (10s clip) | Yes | https://www.minimax.io/ |
| **OpenAI TTS** | High | 6 built-in | No | Yes | https://platform.openai.com/docs/api-reference/audio/createSpeech |
| **Google Cloud TTS** | High | 400+ | No | Yes | https://cloud.google.com/text-to-speech/docs |
| **HF Inference** | Varies | Model-dependent | Model-dependent | Some | https://huggingface.co/docs/api-inference/tasks/text-to-speech |

## ElevenLabs (Highest Quality Cloud)

```bash
curl -X POST "https://api.elevenlabs.io/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM" \
  -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"text": "Hello world", "model_id": "eleven_multilingual_v2"}'
```

## MiniMax / Hailuo (Best Value for Talking-Head Content)

$5/month for 120 minutes. Voice clone from 10s clip. High default quality, less tuning than ElevenLabs. Best for talking-head videos when cost > peak quality.

```bash
curl -X POST "https://api.minimax.chat/v1/t2a_v2" \
  -H "Authorization: Bearer ${MINIMAX_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "speech-02-hd", "text": "Hello world", "voice_setting": {"voice_id": "your-cloned-voice-id"}}'
```

## OpenAI TTS

Models: `tts-1` (fast), `tts-1-hd` (higher quality). Voices: alloy, echo, fable, onyx, nova, shimmer.

```bash
curl https://api.openai.com/v1/audio/speech \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "tts-1-hd", "input": "Hello world", "voice": "alloy"}'
```

## Related

- `tools/voice/voice-models.md` - Voice bridge engines and model selection index
- `tools/voice/voice-ai-models.md` - Complete model comparison (TTS, STT, S2S)
- `tools/voice/local-tts-models.md` - Local open-weight TTS models
- `tools/voice/qwen3-tts.md` - Qwen3-TTS (recommended for quality + multilingual)
- `content/production-audio.md` - Audio production workflows
