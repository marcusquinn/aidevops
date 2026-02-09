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

# Pipecat-OpenCode Voice Bridge

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Source**: [pipecat-ai/pipecat](https://github.com/pipecat-ai/pipecat) (BSD 2-Clause, 10.2k stars)
- **Purpose**: Real-time speech-to-speech conversation with AI coding agents
- **Pipeline**: Mic -> Soniox STT -> Anthropic/OpenAI LLM -> Cartesia TTS -> Speaker
- **Transport**: SmallWebRTCTransport (local, serverless) or Daily.co (cloud, multi-user)
- **Helper**: `voice-helper.sh talk` (simple bridge) or `pipecat-helper.sh start` (full Pipecat pipeline)
- **API keys**: Soniox, Cartesia, Anthropic/OpenAI (store via `aidevops secret set`)

**When to Use**: Read this when building real-time voice conversation with AI agents. For simpler voice interaction, use `voice-helper.sh talk` (the existing voice bridge). Use this Pipecat approach when you need: streaming TTS as text arrives, barge-in interruption, S2S mode, multi-user WebRTC rooms, or phone integration.

**Comparison with existing voice bridge**:

| Feature | voice-bridge.py | Pipecat pipeline |
|---------|----------------|------------------|
| Latency | ~6-8s round-trip | ~1-3s (streaming) |
| Barge-in | Mic muted during TTS | True interruption via VAD |
| Streaming TTS | No (full response then speak) | Yes (speak as text arrives) |
| S2S mode | No | Yes (OpenAI Realtime, etc.) |
| Transport | Local sounddevice | WebRTC (local or cloud) |
| Setup complexity | Low (pip install) | Medium (Pipecat + services) |
| LLM integration | OpenCode CLI subprocess | Direct API (Anthropic/OpenAI) |

<!-- AI-CONTEXT-END -->

## Architecture

### STT + LLM + TTS Pipeline (Default)

```text
Microphone -> [SmallWebRTCTransport] -> [Soniox STT] -> [Anthropic LLM] -> [Cartesia TTS] -> Speaker
                                              |                |                   |
                                         Real-time        Claude Sonnet       Sonic voice
                                         streaming        with tools          low-latency
                                         60+ languages    function calling    word timestamps
```

Each component runs as a Pipecat processor in an async pipeline. Audio streams via WebRTC (local serverless or Daily.co cloud). The LLM receives transcribed text and generates responses that stream directly to TTS.

### S2S Mode (Speech-to-Speech)

```text
Microphone -> [Transport] -> [OpenAI Realtime / Gemini Multimodal Live] -> [Transport] -> Speaker
```

S2S providers handle STT, reasoning, and TTS in a single model call. Lower latency (~500ms) but less control over individual components. Supported providers via Pipecat: OpenAI Realtime, AWS Nova Sonic, Gemini Multimodal Live, Ultravox.

## Setup

### Prerequisites

- Python 3.10+ (3.12 recommended)
- macOS (Apple Silicon) or Linux with CUDA
- API keys: Soniox, Cartesia, Anthropic (or OpenAI)

### Install Pipecat

```bash
# Create project directory
mkdir -p ~/.aidevops/.agent-workspace/work/pipecat-opencode
cd ~/.aidevops/.agent-workspace/work/pipecat-opencode

# Create virtual environment
python3.12 -m venv .venv
source .venv/bin/activate

# Install Pipecat with required services
pip install "pipecat-ai[soniox,cartesia,anthropic,silero,smallwebrtc]"

# For OpenAI LLM (alternative to Anthropic)
pip install "pipecat-ai[openai]"

# For S2S mode (OpenAI Realtime)
pip install "pipecat-ai[openai-realtime]"
```

### Store API Keys

```bash
# Store keys securely (never paste in AI conversation)
aidevops secret set SONIOX_API_KEY
aidevops secret set CARTESIA_API_KEY
aidevops secret set ANTHROPIC_API_KEY

# Or add to credentials file
# ~/.config/aidevops/credentials.sh (600 permissions)
```

## Usage

### Minimal Pipeline (Local, Anthropic LLM)

```python
"""Pipecat voice agent with Soniox STT + Anthropic LLM + Cartesia TTS."""

import os
from dotenv import load_dotenv

from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.runner import PipelineRunner
from pipecat.pipeline.task import PipelineParams, PipelineTask
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.soniox.stt import SonioxSTTService
from pipecat.services.anthropic.llm import AnthropicLLMService
from pipecat.transports.base_transport import TransportParams

load_dotenv(override=True)

async def run_agent():
    # Services
    stt = SonioxSTTService(api_key=os.getenv("SONIOX_API_KEY"))
    tts = CartesiaTTSService(
        api_key=os.getenv("CARTESIA_API_KEY"),
        voice_id="71a7ad14-091c-4e8e-a314-022ece01c121",  # British Reading Lady
    )
    llm = AnthropicLLMService(
        api_key=os.getenv("ANTHROPIC_API_KEY"),
        model="claude-sonnet-4-20250514",
    )

    # System prompt for voice interaction
    messages = [
        {
            "role": "system",
            "content": (
                "You are an AI DevOps assistant in a voice conversation. "
                "Keep responses to 1-3 short sentences. Use plain spoken English "
                "suitable for text-to-speech. No markdown, no code blocks, no "
                "bullet points. When asked to perform tasks (edit files, run "
                "commands, git operations), confirm the action and report the "
                "outcome briefly. If genuinely ambiguous, ask for clarification."
            ),
        },
    ]

    # Context and aggregators
    context = LLMContext(messages)
    user_aggregator, assistant_aggregator = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            vad_analyzer=SileroVADAnalyzer(),
        ),
    )

    # Transport (local serverless WebRTC)
    from pipecat.transports.small_webrtc.transport import SmallWebRTCTransport

    transport = SmallWebRTCTransport(
        params=TransportParams(
            audio_in_enabled=True,
            audio_out_enabled=True,
        ),
    )

    # Pipeline
    pipeline = Pipeline([
        transport.input(),
        stt,
        user_aggregator,
        llm,
        tts,
        transport.output(),
        assistant_aggregator,
    ])

    task = PipelineTask(
        pipeline,
        params=PipelineParams(
            enable_metrics=True,
            enable_usage_metrics=True,
        ),
    )

    runner = PipelineRunner()
    await runner.run(task)
```

### With OpenAI LLM (Alternative)

Replace the Anthropic service with OpenAI:

```python
from pipecat.services.openai.llm import OpenAILLMService

llm = OpenAILLMService(
    api_key=os.getenv("OPENAI_API_KEY"),
    model="gpt-4o",
)
```

### S2S Mode (OpenAI Realtime)

For lowest latency, use OpenAI's speech-to-speech model directly:

```python
from pipecat.services.openai_realtime.llm import OpenAIRealtimeLLMService

s2s = OpenAIRealtimeLLMService(
    api_key=os.getenv("OPENAI_API_KEY"),
    model="gpt-4o-realtime-preview",
    voice="alloy",
)

# S2S replaces STT + LLM + TTS in the pipeline
pipeline = Pipeline([
    transport.input(),
    s2s,
    transport.output(),
])
```

### Daily.co Transport (Cloud, Multi-User)

For cloud deployment or multi-user voice rooms:

```python
from pipecat.transports.daily.transport import DailyTransport, DailyParams

transport = DailyTransport(
    room_url="https://your-domain.daily.co/room-name",
    token="your-daily-token",
    "AI DevOps Agent",
    DailyParams(
        audio_in_enabled=True,
        audio_out_enabled=True,
    ),
)
```

Requires a Daily.co account and API key. See [Daily.co docs](https://docs.daily.co/).

## Integration with aidevops

### Voice-Driven DevOps

The Pipecat pipeline can use Anthropic's function calling to execute DevOps tasks:

```python
# Add tool definitions to the LLM context
tools = [
    {
        "name": "run_command",
        "description": "Execute a shell command in the project directory",
        "input_schema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Shell command to run"},
            },
            "required": ["command"],
        },
    },
    {
        "name": "edit_file",
        "description": "Edit a file in the project",
        "input_schema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "content": {"type": "string"},
            },
            "required": ["path", "content"],
        },
    },
]

llm = AnthropicLLMService(
    api_key=os.getenv("ANTHROPIC_API_KEY"),
    model="claude-sonnet-4-20250514",
    tools=tools,
)
```

### Connecting to OpenCode Server

For deeper integration with an existing OpenCode session, the pipeline LLM can proxy through the OpenCode server API:

```python
# Option 1: Use Anthropic/OpenAI directly (recommended for Pipecat)
# The LLM service handles streaming natively with Pipecat's pipeline

# Option 2: Proxy through OpenCode server for session continuity
# Use OpenCode's HTTP API to submit prompts and stream responses
# See tools/ai-assistants/opencode-server.md for API details
# Note: This adds latency vs direct API calls
```

Direct API integration (Option 1) is recommended for Pipecat because it enables native streaming, function calling, and interruption handling. Use the OpenCode proxy (Option 2) only when you need to share context with an existing OpenCode session.

### Existing Voice Bridge Comparison

The existing `voice-helper.sh talk` / `voice-bridge.py` provides a simpler approach:

```bash
# Simple voice bridge (existing, works today)
voice-helper.sh talk

# Pipecat pipeline (this subagent, more capable)
# Requires Pipecat setup + web client for WebRTC
```

**When to use which:**

- **voice-bridge.py**: Quick voice interaction, no web client needed, works in terminal
- **Pipecat pipeline**: Production voice agents, streaming TTS, barge-in, S2S, phone integration, multi-user

## Service Options

### STT (Speech-to-Text)

| Service | Latency | Languages | Notes |
|---------|---------|-----------|-------|
| **Soniox** (recommended) | Low | 60+ | Real-time WebSocket, multilingual |
| Deepgram | Low | 30+ | Nova-2 model, good accuracy |
| Google Cloud STT | Medium | 125+ | Most languages |
| Whisper (local) | Medium | 99 | No API key, runs on device |

### LLM (Language Model)

| Service | Latency | Notes |
|---------|---------|-------|
| **Anthropic** (recommended) | ~1-2s | Claude Sonnet, function calling, prompt caching |
| OpenAI | ~1-2s | GPT-4o, mature function calling |
| Google Gemini | ~1-2s | Gemini 2.5 Pro/Flash |
| Local (Ollama/LM Studio) | Varies | No API cost, requires GPU |

### TTS (Text-to-Speech)

| Service | Latency | Notes |
|---------|---------|-------|
| **Cartesia Sonic** (recommended) | ~200ms | WebSocket streaming, word timestamps, SSML |
| ElevenLabs | ~300ms | High quality, voice cloning |
| OpenAI TTS | ~400ms | Simple API, good quality |
| Kokoro (local) | ~100ms | No API key, macOS MLX |

### S2S (Speech-to-Speech)

| Service | Latency | Notes |
|---------|---------|-------|
| OpenAI Realtime | ~500ms | Most mature, lowest latency |
| AWS Nova Sonic | ~600ms | AWS ecosystem |
| Gemini Multimodal Live | ~500ms | Google ecosystem |
| Ultravox | ~700ms | Open weights available |

## Web Client

Pipecat voice agents communicate via WebRTC. You need a web client to connect:

### Using voice-ui-kit (Recommended)

```bash
# Clone the voice UI kit
git clone https://github.com/pipecat-ai/voice-ui-kit
cd voice-ui-kit

npm install
npm run dev

# Navigate to http://localhost:5173 in your browser
```

### Using kwindla/macos-local-voice-agents

For a complete local setup with debug console:

```bash
git clone https://github.com/kwindla/macos-local-voice-agents
cd macos-local-voice-agents

# Start the bot
cd server && uv run bot.py

# Start the web client
cd client && npm install && npm run dev
```

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

## Configuration

### Environment Variables

```bash
# Required for STT+LLM+TTS pipeline
SONIOX_API_KEY=       # Soniox STT
CARTESIA_API_KEY=     # Cartesia TTS
ANTHROPIC_API_KEY=    # Anthropic LLM (or OPENAI_API_KEY)

# Optional
DAILY_API_KEY=        # Daily.co transport (cloud mode)
OPENAI_API_KEY=       # OpenAI LLM or Realtime S2S

# Performance
HF_HUB_OFFLINE=1     # Skip model update checks (faster startup)
```

### Recommended Local Configuration (macOS)

For lowest latency on Apple Silicon:

- **STT**: Soniox (cloud, real-time) or MLX Whisper (local, ~1.4s)
- **LLM**: Anthropic Claude Sonnet (cloud) or local via LM Studio
- **TTS**: Cartesia Sonic (cloud, streaming) or Kokoro (local, MLX)
- **Transport**: SmallWebRTCTransport (serverless, no Daily.co needed)

### Recommended Cloud Configuration

For production deployment:

- **STT**: Soniox
- **LLM**: Anthropic Claude Sonnet
- **TTS**: Cartesia Sonic
- **Transport**: Daily.co (managed WebRTC, global infrastructure)

## See Also

- `tools/voice/cloud-voice-agents.md` - Cloud voice agents (GPT-4o Realtime, MiniCPM-o, NVIDIA Nemotron)
- `tools/voice/speech-to-speech.md` - HuggingFace S2S pipeline (alternative approach)
- `scripts/voice-helper.sh` - Simple voice bridge (existing, terminal-based)
- `scripts/voice-bridge.py` - Voice bridge Python implementation
- `tools/voice/transcription.md` - Standalone transcription
- `tools/voice/voice-models.md` - Voice AI model catalog
- `services/communications/twilio.md` - Phone integration with Pipecat
