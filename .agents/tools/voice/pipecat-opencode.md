---
description: "Pipecat-OpenCode voice bridge - real-time speech-to-speech conversation with AI coding agents via Pipecat pipeline"
mode: subagent
upstream_url: https://github.com/pipecat-ai/pipecat
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

# Pipecat-OpenCode Voice Bridge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Source**: [pipecat-ai/pipecat](https://github.com/pipecat-ai/pipecat) (BSD 2-Clause, 10.3k stars, v0.0.102+)
- **Purpose**: Real-time speech-to-speech conversation with AI coding agents
- **Pipeline**: Mic -> Soniox STT -> Anthropic/OpenAI LLM -> Cartesia TTS -> Speaker (each component = async Pipecat processor)
- **S2S mode**: Collapses STT+LLM+TTS into one model call (~500ms). Providers: OpenAI Realtime, AWS Nova Sonic, Gemini Multimodal Live, Ultravox
- **Transport**: SmallWebRTCTransport (local, serverless) or Daily.co (cloud, multi-user)
- **Helper**: `pipecat-helper.sh [setup|start|stop|status|client|keys|logs]`
- **Simple alternative**: `voice-helper.sh talk` (terminal-based, no web client)
- **API keys**: Soniox, Cartesia, Anthropic/OpenAI (store via `aidevops secret set`)
- **Reference impl**: [kwindla/macos-local-voice-agents](https://github.com/kwindla/macos-local-voice-agents) (all-local, <800ms latency)

**Use Pipecat** when you need streaming TTS, barge-in interruption, S2S mode, multi-user WebRTC, or phone integration. For simpler use, prefer `voice-helper.sh talk`.

| Feature | voice-bridge.py | Pipecat pipeline |
|---------|----------------|------------------|
| Latency | ~6-8s round-trip | ~1-3s (streaming) |
| Barge-in | Mic muted during TTS | True interruption via VAD |
| Streaming TTS | No | Yes |
| S2S mode | No | Yes (OpenAI Realtime, etc.) |
| Transport | Local sounddevice | WebRTC (local or cloud) |
| Setup complexity | Low | Medium |
| LLM integration | OpenCode CLI subprocess | Direct API |

<!-- AI-CONTEXT-END -->

## Setup

```bash
# One-command setup (recommended)
pipecat-helper.sh setup           # Anthropic (default)
pipecat-helper.sh setup openai    # OpenAI
pipecat-helper.sh setup both      # Both providers

# Store API keys (never paste in AI conversation)
aidevops secret set SONIOX_API_KEY
aidevops secret set CARTESIA_API_KEY
aidevops secret set ANTHROPIC_API_KEY

# Start agent + web client
pipecat-helper.sh start
# Open http://localhost:3000 and click Connect to talk
```

### Manual Install

```bash
mkdir -p ~/.aidevops/.agent-workspace/work/pipecat-voice-agent
cd ~/.aidevops/.agent-workspace/work/pipecat-voice-agent
python3.12 -m venv .venv && source .venv/bin/activate
pip install "pipecat-ai[soniox,cartesia,anthropic,silero,webrtc]"
pip install python-dotenv uvicorn fastapi
pip install "pipecat-ai[openai]"          # optional: OpenAI LLM
pip install "pipecat-ai[openai-realtime]" # optional: S2S mode
```

## Core Pipeline (v0.0.80+)

`pipecat-helper.sh setup` generates a complete `bot.py`. Core pattern:

```python
"""Pipecat voice agent with Soniox STT + Anthropic LLM + Cartesia TTS."""
import os
from dotenv import load_dotenv
from pipecat.audio.vad.silero import SileroVADAnalyzer, VADParams
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.aggregators.openai_llm_context import OpenAILLMContext
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.soniox.stt import SonioxSTTService
from pipecat.services.anthropic.llm import AnthropicLLMService
from pipecat.transports.network.small_webrtc import SmallWebRTCTransport
from pipecat.transports.network.webrtc_connection import SmallWebRTCConnection
from pipecat.transports.base_transport import TransportParams

load_dotenv(override=True)

async def run_agent(webrtc_connection: SmallWebRTCConnection):
    stt = SonioxSTTService(api_key=os.getenv("SONIOX_API_KEY"))
    tts = CartesiaTTSService(
        api_key=os.getenv("CARTESIA_API_KEY"),
        voice_id="71a7ad14-091c-4e8e-a314-022ece01c121",  # British Reading Lady
    )
    llm = AnthropicLLMService(
        api_key=os.getenv("ANTHROPIC_API_KEY"),
        model="claude-sonnet-4-6",
    )
    messages = [{
        "role": "system",
        "content": (
            "You are an AI DevOps assistant in a voice conversation. "
            "Keep responses to 1-3 short sentences. Use plain spoken English "
            "suitable for text-to-speech. No markdown, no code blocks, no "
            "bullet points. When asked to perform tasks, confirm and report briefly."
        ),
    }]
    context = OpenAILLMContext(messages)
    context_aggregator = llm.create_context_aggregator(context)
    transport = SmallWebRTCTransport(
        webrtc_connection=webrtc_connection,
        params=TransportParams(
            audio_in_enabled=True, audio_out_enabled=True,
            vad_enabled=True,
            vad_analyzer=SileroVADAnalyzer(params=VADParams(stop_secs=0.3)),
        ),
    )
    pipeline = Pipeline([
        transport.input(), stt, context_aggregator.user(),
        llm, tts, transport.output(), context_aggregator.assistant(),
    ])
    task = PipelineTask(pipeline, params=PipelineParams(
        allow_interruptions=True, enable_metrics=True, enable_usage_metrics=True,
    ))
    await PipelineRunner(handle_sigint=False).run(task)
```

**Signaling**: `SmallWebRTCConnection` is created from a WebRTC offer via a FastAPI `/api/offer` endpoint. See generated `bot.py` or [macos-local-voice-agents](https://github.com/kwindla/macos-local-voice-agents).

## Alternative Configurations

```python
# OpenAI LLM (replace Anthropic)
from pipecat.services.openai.llm import OpenAILLMService
llm = OpenAILLMService(api_key=os.getenv("OPENAI_API_KEY"), model="gpt-4o")

# S2S mode (~500ms latency)
from pipecat.services.openai_realtime.llm import OpenAIRealtimeLLMService
s2s = OpenAIRealtimeLLMService(api_key=os.getenv("OPENAI_API_KEY"), model="gpt-4o-realtime-preview", voice="alloy")
pipeline = Pipeline([transport.input(), s2s, transport.output()])

# Daily.co transport (cloud, multi-user)
from pipecat.transports.daily.transport import DailyTransport, DailyParams
transport = DailyTransport(
    room_url="https://your-domain.daily.co/room-name", token="your-daily-token",
    "AI DevOps Agent", DailyParams(audio_in_enabled=True, audio_out_enabled=True),
)
```

## Integration with aidevops

```python
tools = [
    {"name": "run_command", "description": "Execute a shell command",
     "input_schema": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}},
    {"name": "edit_file", "description": "Edit a file in the project",
     "input_schema": {"type": "object", "properties": {"path": {"type": "string"}, "content": {"type": "string"}}, "required": ["path", "content"]}},
]
llm = AnthropicLLMService(api_key=os.getenv("ANTHROPIC_API_KEY"), model="claude-sonnet-4-6", tools=tools)
```

For session continuity with an existing OpenCode session, proxy through the OpenCode server API (adds latency vs direct API). See `tools/ai-assistants/opencode-server.md`.

## Service Options

Recommended defaults marked with **(rec)**. All services are swappable Pipecat processors.

| Type | Service | Latency | Notes |
|------|---------|---------|-------|
| STT | **Soniox** (rec) | Low | Real-time WebSocket, 60+ languages |
| STT | Deepgram | Low | Nova-2, 30+ languages |
| STT | Google Cloud STT | Medium | 125+ languages |
| STT | Whisper (local) | Medium | No API key, 99 languages |
| LLM | **Anthropic** (rec) | ~1-2s | Claude Sonnet, function calling, prompt caching |
| LLM | OpenAI | ~1-2s | GPT-4o, mature function calling |
| LLM | Google Gemini | ~1-2s | Gemini 2.5 Pro/Flash |
| LLM | Local (Ollama/LM Studio) | Varies | No API cost, requires GPU |
| TTS | **Cartesia Sonic** (rec) | ~200ms | WebSocket streaming, word timestamps, SSML |
| TTS | ElevenLabs | ~300ms | High quality, voice cloning |
| TTS | OpenAI TTS | ~400ms | Simple API |
| TTS | Kokoro (local) | ~100ms | No API key, macOS MLX |
| S2S | OpenAI Realtime | ~500ms | Most mature, lowest latency |
| S2S | AWS Nova Sonic | ~600ms | AWS ecosystem |
| S2S | Gemini Multimodal Live | ~500ms | Google ecosystem |
| S2S | Ultravox | ~700ms | Open weights available |

## Web Client

```bash
pipecat-helper.sh client   # Built-in — opens http://localhost:3000

# Custom UI
git clone https://github.com/pipecat-ai/voice-ui-kit
cd voice-ui-kit/examples/01-console && npm install && npm run dev

# All-local (MLX Whisper + local LLM + Kokoro TTS, <800ms)
git clone https://github.com/kwindla/macos-local-voice-agents
cd macos-local-voice-agents/server && uv run bot.py
# In another terminal: cd client && npm install && npm run dev
```

Key npm packages: `@pipecat-ai/client-js`, `@pipecat-ai/client-react`, `@pipecat-ai/small-webrtc-transport`, `@pipecat-ai/voice-ui-kit`.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ModuleNotFoundError: pipecat` | Activate venv: `source .venv/bin/activate` |
| Soniox connection timeout | Check `SONIOX_API_KEY` is set and valid |
| Cartesia no audio output | Verify `CARTESIA_API_KEY` and voice_id exists |
| High latency (>5s) | Use S2S mode or check network; ensure streaming TTS |
| WebRTC connection fails | Check firewall allows UDP; try Daily.co transport |
| Barge-in not working | Ensure VAD is configured; check mic isn't muted |
| Echo/feedback loop | Use headphones or enable echo cancellation |

## Environment Variables

```bash
SONIOX_API_KEY=       # Soniox STT (required)
CARTESIA_API_KEY=     # Cartesia TTS (required)
ANTHROPIC_API_KEY=    # Anthropic LLM (required, or OPENAI_API_KEY)
DAILY_API_KEY=        # Daily.co transport (cloud mode)
OPENAI_API_KEY=       # OpenAI LLM or Realtime S2S
HF_HUB_OFFLINE=1     # Skip model update checks (faster startup)
```

## See Also

- `scripts/pipecat-helper.sh` - Pipecat lifecycle management
- `tools/voice/cloud-voice-agents.md` - Cloud voice agents (GPT-4o Realtime, MiniCPM-o, NVIDIA Nemotron)
- `tools/voice/speech-to-speech.md` - HuggingFace S2S pipeline
- `scripts/voice-helper.sh` - Simple voice bridge (terminal-based)
- `tools/voice/transcription.md` - Standalone transcription
- `tools/voice/voice-models.md` - Voice AI model catalog
- `services/communications/twilio.md` - Phone integration with Pipecat
- [pipecat-ai/voice-ui-kit](https://github.com/pipecat-ai/voice-ui-kit) - React web client components
- [kwindla/macos-local-voice-agents](https://github.com/kwindla/macos-local-voice-agents) - All-local reference implementation
