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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloud TTS APIs

API keys required. Store via `aidevops secret set <KEY_NAME>`.

## Provider Comparison

| Provider | Quality | Voices | Voice Clone | Streaming | Docs |
|----------|---------|--------|-------------|-----------|------|
| **ElevenLabs** | Highest | 1000+ | Yes (instant) | Yes | https://elevenlabs.io/docs/api-reference/text-to-speech |
| **MiniMax (Hailuo)** | High | Multiple | Yes (10s clip) | Yes | https://www.minimax.io/ |
| **OpenAI TTS** | High | Multiple built-in | No | Yes | https://platform.openai.com/docs/api-reference/audio/createSpeech |
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

Models: `gpt-4o-mini-tts` (supports delivery-style `instructions`), `tts-1` (fast), `tts-1-hd` (higher quality). Built-in voices include alloy, ash, ballad, coral, echo, fable, onyx, nova, sage, shimmer and verse; check the API for current availability.

```bash
curl https://api.openai.com/v1/audio/speech \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model": "gpt-4o-mini-tts", "input": "Hello world", "voice": "alloy", "instructions": "Speak warmly and clearly."}'
```

## NanoGPT (one key, many providers)

Discover live model IDs, pricing, `supported_parameters.voices` and `max_chars` before choosing a voice. Prices and supported fields change; do not rely on static price lists. The same speech endpoint also exposes music and sound-effect models.

```bash
aidevops secret NANOGPT_API_KEY -- sh -c 'curl -H "Authorization: Bearer ${NANOGPT_API_KEY}" "https://api.nano-gpt.com/api/v1/audio-models?type=tts&detailed=true"'
aidevops secret NANOGPT_API_KEY -- sh -c 'curl -X POST "https://api.nano-gpt.com/api/v1/audio/speech" \
  -H "Authorization: Bearer ${NANOGPT_API_KEY}" -H "Content-Type: application/json" \
  -d '\''{"model":"<discovered-model-id>","input":"Hello world","voice":"<supported-voice>"}'\'''
```

Replace the example model and voice with an ID and supported voice from discovery. A response containing `{"status":"pending","runId":...}` is **already charged** (observed with ElevenLabs and Qwen), even on a synchronous request. Poll `GET /api/tts/status?runId=<runId>&model=<model>&cost=<cost>&paymentSource=<paymentSource>&isApiRequest=<isApiRequest>` using the ticket fields; **do not resubmit** the generation request or it may bill twice.

Music requests use the same `POST /api/v1/audio/speech` route; discover model IDs and required parameters before submitting:

| Model family | Additional field |
|--------------|------------------|
| MiniMax Music 3 | Instrumental flag |
| ACE-Step | `tags` |
| Mureka | `prompt` |
| MiniMax Music 2.6 | `lyrics` |

Missing model-specific fields can return an unbilled 400. NanoGPT's OpenAI TTS upstream has returned `invalid_api_key` (unbilled 401) on both `/api/tts` and `/api/v1/audio/speech`; treat that upstream route as intermittently unavailable rather than repeatedly retrying it.

## ChatGPT OAuth scope

The ChatGPT OAuth pool's Codex responses route covers images, **not** TTS. OpenAI `/v1/audio/speech` requires an OpenAI Platform API key; OAuth pool credentials are not a substitute.

## Related

- `tools/voice/voice-models.md` - Voice bridge engines and model selection index
- `tools/voice/voice-ai-models.md` - Complete model comparison (TTS, STT, S2S)
- `tools/voice/local-tts-models.md` - Local open-weight TTS models
- `tools/voice/qwen3-tts.md` - Qwen3-TTS (recommended for quality + multilingual)
- `content/production-audio.md` - Audio production workflows
