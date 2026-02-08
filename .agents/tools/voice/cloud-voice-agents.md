---
description: Cloud and local speech-to-speech (S2S) voice agent providers via Pipecat
mode: subagent
tools:
  read: true
  bash: true
  webfetch: true
---

# Cloud Voice Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Build real-time voice agents using cloud and local S2S models
- **Framework**: [Pipecat](https://github.com/pipecat-ai/pipecat) (BSD 2-Clause, 10.2k stars)
- **Providers**: OpenAI Realtime, AWS Nova Sonic, Gemini Multimodal Live, Ultravox, NVIDIA Nemotron, MiniCPM-o (local)
- **Transport**: Daily.co WebRTC (cloud), SmallWebRTCTransport (local)

<!-- AI-CONTEXT-END -->

## S2S Provider Comparison

| Provider | Type | Latency | Quality | Cost | Notes |
|----------|------|---------|---------|------|-------|
| **OpenAI Realtime** | Cloud | ~300ms | Excellent | $$$ | Most mature Pipecat S2S integration |
| **AWS Nova Sonic** | Cloud | ~400ms | Good | $$ | AWS ecosystem, Bedrock integration |
| **Gemini Multimodal Live** | Cloud | ~350ms | Good | $$ | Multimodal (voice + vision) |
| **Ultravox** | Cloud | ~250ms | Good | $$ | Purpose-built for voice agents |
| **NVIDIA Nemotron** | Cloud/API | ~500ms | Good | $ | Free cloud credits, NVIDIA GPU for local |
| **MiniCPM-o 4.5** | Local | ~1-2s | Good | Free | 9B params, Apache-2.0, full-duplex |
| **HuggingFace S2S** | Local | ~2-3s | Good | Free | Modular pipeline (see `speech-to-speech.md`) |

## OpenAI Realtime API

Most mature S2S integration with Pipecat.

```python
from pipecat.services.openai_realtime import OpenAIRealtimeService
from pipecat.transports.services.daily import DailyTransport

# S2S mode - audio in, audio out, no separate STT/TTS
service = OpenAIRealtimeService(
    api_key="...",
    model="gpt-4o-realtime-preview",
    voice="alloy",  # alloy, echo, fable, onyx, nova, shimmer
)

# Supports: function calling, interruption, turn detection
```

**Features**: Native function calling, voice activity detection, barge-in, 6 voices.

**Docs**: <https://docs.pipecat.ai/server/services/s2s/openai>

## AWS Nova Sonic

```python
from pipecat.services.aws_nova_sonic import AWSNovaSonicService

service = AWSNovaSonicService(
    region="us-east-1",
    model_id="amazon.nova-sonic-v1:0",
)
```

**Docs**: <https://docs.pipecat.ai/server/services/s2s/nova-sonic>

## Gemini Multimodal Live

Supports voice + vision simultaneously.

```python
from pipecat.services.google import GoogleMultimodalLiveService

service = GoogleMultimodalLiveService(
    api_key="...",
    model="gemini-2.0-flash-exp",
    voice_name="Puck",  # Puck, Charon, Kore, Fenrir, Aoede
)
```

**Docs**: <https://docs.pipecat.ai/server/services/s2s/gemini-multimodal-live>

## Ultravox

Purpose-built for voice agents with native tool use.

```python
from pipecat.services.ultravox import UltravoxService

service = UltravoxService(
    api_key="...",
    model="fixie-ai/ultravox-v0.5",
    voice="lily-english",
)
```

**Docs**: <https://docs.pipecat.ai/server/services/s2s/ultravox>

## NVIDIA Nemotron

Cloud via NVIDIA API (free credits available).

```python
# Via Pipecat NVIDIA integration
from pipecat.services.nvidia import NVIDIANemotronService

service = NVIDIANemotronService(
    api_key="...",  # NVIDIA API key
    model="nvidia/nemotron-mini-4b-instruct",
)
```

**Local**: Requires NVIDIA GPU. Use NVIDIA NIM containers.

**Ref**: <https://www.daily.co/blog/building-voice-agents-with-nvidia-open-models/>

## MiniCPM-o (Local S2S)

Full-duplex voice+vision+text, runs on Mac via llama.cpp-omni.

```bash
# Install
git clone https://github.com/OpenBMB/MiniCPM-o
pip install -r requirements.txt

# Run (requires ~18GB RAM for 9B model)
python demo/s2s_demo.py --model openbmb/MiniCPM-o-2_6

# WebRTC demo
python demo/webrtc_demo.py --port 8080
```

- **Models**: MiniCPM-o 2.6 (lighter), MiniCPM-o 4.5 (9B, best quality)
- **License**: Apache-2.0
- **Stars**: 23k
- **Features**: Full-duplex conversation, vision understanding, voice cloning

## Pipecat Pipeline Setup

```bash
# Install Pipecat with all S2S providers
pip install "pipecat-ai[daily,openai,google,aws,cartesia,soniox]"

# Store API keys
aidevops secret set OPENAI_API_KEY
aidevops secret set DAILY_API_KEY
aidevops secret set CARTESIA_API_KEY
aidevops secret set SONIOX_API_KEY
```

### Basic Voice Agent

```python
import asyncio
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.services.openai_realtime import OpenAIRealtimeService
from pipecat.transports.services.daily import DailyTransport

async def main():
    transport = DailyTransport(
        room_url="https://your-domain.daily.co/room",
        token="...",
    )

    s2s = OpenAIRealtimeService(
        api_key="...",
        model="gpt-4o-realtime-preview",
        system_prompt="You are a helpful DevOps assistant.",
    )

    pipeline = Pipeline([transport.input(), s2s, transport.output()])
    runner = PipelineRunner()
    await runner.run(pipeline)

asyncio.run(main())
```

## Use Cases

| Use Case | Recommended Provider | Why |
|----------|---------------------|-----|
| DevOps voice assistant | OpenAI Realtime | Best function calling, lowest latency |
| Customer service bot | Ultravox | Purpose-built, native tool use |
| Multimodal (voice+camera) | Gemini Multimodal Live | Vision + voice simultaneously |
| Privacy-sensitive | MiniCPM-o (local) | No data leaves machine |
| AWS ecosystem | Nova Sonic | Native Bedrock integration |
| Budget-conscious | Nemotron (free credits) | NVIDIA free tier |

## Related

- `tools/voice/pipecat-opencode.md` - Pipecat + OpenCode integration
- `tools/voice/speech-to-speech.md` - HuggingFace local S2S pipeline
- `tools/voice/voice-ai-models.md` - TTS/STT model catalog
- `tools/voice/transcription.md` - Transcription backends
