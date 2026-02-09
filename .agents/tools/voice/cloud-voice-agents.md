---
description: "Cloud voice agents - deploy S2S voice agents using GPT-4o Realtime, MiniCPM-o, and NVIDIA Nemotron Speech"
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

# Cloud Voice Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Deploy speech-to-speech voice agents in the cloud using leading S2S models
- **Models**: GPT-4o Realtime (OpenAI), MiniCPM-o 2.6 (open weights), NVIDIA Nemotron Speech (Riva NIM)
- **Frameworks**: Pipecat (recommended), OpenAI Agents SDK, custom WebSocket/WebRTC
- **Local S2S pipeline**: `tools/voice/speech-to-speech.md` (cascaded VAD+STT+LLM+TTS)
- **Pipecat integration**: `tools/voice/pipecat-opencode.md` (real-time voice bridge)
- **Model catalog**: `tools/voice/voice-ai-models.md` (full model comparison)

**When to use**: Building production voice agents, phone bots, customer service agents, or real-time conversational AI that runs in the cloud. For local/development voice interaction, use `voice-helper.sh talk` instead.

<!-- AI-CONTEXT-END -->

## Architecture Overview

Cloud voice agents use one of two approaches:

```text
Approach 1: Native S2S (single model)
  Audio In -> [S2S Model] -> Audio Out
  Examples: GPT-4o Realtime, MiniCPM-o omni mode

Approach 2: Cascaded Pipeline (composable)
  Audio In -> [STT] -> [LLM] -> [TTS] -> Audio Out
  Examples: Parakeet STT + Claude + Magpie TTS (via NVIDIA Riva)
```

Native S2S is lower latency but less controllable. Cascaded pipelines let you swap components independently and are easier to debug.

## Model Comparison

| Model | Type | Latency | VRAM | License | Languages | Best For |
|-------|------|---------|------|---------|-----------|----------|
| GPT-4o Realtime | Cloud API | ~300ms | N/A | Proprietary | 50+ | Production cloud, lowest latency |
| MiniCPM-o 2.6 | Open weights | ~500ms | 8-16GB | Apache-2.0 | EN, ZH (bilingual) | Self-hosted, privacy, multimodal |
| NVIDIA Nemotron Speech | NIM API/Self-host | ~200-400ms | Varies | Mixed | 25+ (ASR), 17+ (TTS) | Enterprise, on-prem, NVIDIA GPUs |
| Gemini 2.0 Live | Cloud API | ~350ms | N/A | Proprietary | 40+ | Google ecosystem, multimodal |
| AWS Nova Sonic | Cloud API | ~600ms | N/A | Proprietary | 7 | AWS ecosystem |

## GPT-4o Realtime

OpenAI's native speech-to-speech model. GA (general availability) as of 2025. Supports WebRTC (browser), WebSocket (server), and SIP (telephony) connections.

### Key Features

- Native audio understanding and generation (no STT/TTS intermediary)
- Emotion-aware voice output with 9+ voice options
- Function calling during voice conversations
- Input transcription for logging/compliance
- WebRTC for browser, WebSocket for server, SIP for VoIP telephony
- Model name: `gpt-realtime` (GA) or `gpt-4o-realtime-preview` (legacy)

### Setup

```bash
# Store API key
aidevops secret set OPENAI_API_KEY
```

### Via OpenAI Agents SDK (Recommended for Browser)

```javascript
import { RealtimeAgent, RealtimeSession } from "@openai/agents/realtime";

const agent = new RealtimeAgent({
    name: "DevOps Assistant",
    instructions: "You are an AI DevOps assistant. Keep responses brief and spoken.",
});

const session = new RealtimeSession(agent);
await session.connect({ apiKey: "<client-api-key>" });
```

### Via Pipecat (Recommended for Server)

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

### Via WebSocket (Direct)

```python
import websockets, json, os

url = "wss://api.openai.com/v1/realtime?model=gpt-realtime"
headers = {"Authorization": f"Bearer {os.getenv('OPENAI_API_KEY')}"}

async with websockets.connect(url, extra_headers=headers) as ws:
    await ws.send(json.dumps({
        "type": "session.update",
        "session": {
            "type": "realtime",
            "instructions": "You are a helpful voice assistant.",
            "audio": {"output": {"voice": "marin"}},
        },
    }))
```

### Voices

alloy, ash, ballad, coral, echo, fable, marin, sage, shimmer, verse.

### Pricing

Audio input: ~$40/1M tokens. Audio output: ~$80/1M tokens. Cached audio input: ~$2.50/1M tokens. Roughly $0.06/min for typical conversation.

### Docs

- API reference: https://platform.openai.com/docs/guides/realtime
- Voice agents quickstart: https://openai.github.io/openai-agents-js/guides/voice-agents/quickstart/

## MiniCPM-o 2.6

Open-weight omni-modal model (8B params) by OpenBMB. Handles vision, speech, and multimodal live streaming. End-to-end architecture: SigLip-400M + Whisper-medium-300M + ChatTTS-200M + Qwen2.5-7B.

### Key Features

- End-to-end speech conversation (no separate STT/TTS pipeline)
- Bilingual real-time speech (English + Chinese)
- Configurable voices via audio system prompt
- Voice cloning from short reference audio
- Emotion/speed/style control
- Multimodal live streaming (video + audio + text simultaneously)
- Outperforms GPT-4o-realtime on audio understanding benchmarks (ASR, STT translation)
- Runs on consumer GPUs (8GB+ VRAM), iPad, or cloud

### Setup

```bash
pip install torch==2.3.1 torchaudio==2.3.1 transformers==4.44.2 \
    librosa soundfile vector-quantize-pytorch vocos decord moviepy
```

### Basic Speech Conversation

```python
import torch, librosa
from transformers import AutoModel, AutoTokenizer

model = AutoModel.from_pretrained(
    "openbmb/MiniCPM-o-2_6",
    trust_remote_code=True,
    attn_implementation="sdpa",
    torch_dtype=torch.bfloat16,
    init_vision=False,  # speech-only mode
    init_audio=True,
    init_tts=True,
)
model = model.eval().cuda()
tokenizer = AutoTokenizer.from_pretrained(
    "openbmb/MiniCPM-o-2_6", trust_remote_code=True
)
model.init_tts()

# Load reference voice for configurable output
ref_audio, _ = librosa.load("reference_voice.wav", sr=16000, mono=True)
sys_prompt = model.get_sys_prompt(
    ref_audio=ref_audio, mode="audio_assistant", language="en"
)

# Speech input
user_audio, _ = librosa.load("user_question.wav", sr=16000, mono=True)
msgs = [sys_prompt, {"role": "user", "content": [user_audio]}]

res = model.chat(
    msgs=msgs,
    tokenizer=tokenizer,
    sampling=True,
    max_new_tokens=128,
    use_tts_template=True,
    generate_audio=True,
    temperature=0.3,
    output_audio_path="response.wav",
)
```

### Streaming Mode (Low Latency)

```python
model.reset_session()
session_id = "voice-agent-001"

# Prefill system prompt
model.streaming_prefill(
    session_id=session_id, msgs=[sys_prompt], tokenizer=tokenizer
)

# Stream audio chunks and generate responses incrementally
for chunk in audio_chunks:
    model.streaming_prefill(
        session_id=session_id,
        msgs=[{"role": "user", "content": ["<unit>", chunk]}],
        tokenizer=tokenizer,
    )

# Generate streaming response
for r in model.streaming_generate(
    session_id=session_id, tokenizer=tokenizer,
    temperature=0.5, generate_audio=True
):
    play_audio(r.audio_wav, r.sampling_rate)
```

### Deployment Options

| Method | Notes |
|--------|-------|
| HuggingFace Transformers | Default, see code above |
| vLLM | High-throughput server deployment |
| llama.cpp | CPU inference on edge devices |
| Ollama | `ollama run openbmb/minicpm-o2.6` |
| int4 quantized | `openbmb/MiniCPM-o-2_6-int4` (reduced VRAM) |
| GGUF | 16 quantization sizes available |

### Requirements

- Python 3.10+, PyTorch 2.3+
- CUDA GPU with 8GB+ VRAM (16GB recommended for full omni mode)
- `transformers==4.44.2` (specific version required)
- Apple Silicon: via llama.cpp (MPS not directly supported for full model)

### Docs

- GitHub: https://github.com/OpenBMB/MiniCPM-o
- HuggingFace: https://huggingface.co/openbmb/MiniCPM-o-2_6
- Ollama: https://ollama.com/openbmb/minicpm-o2.6

## NVIDIA Nemotron Speech (Riva NIM)

NVIDIA's speech AI stack for enterprise voice agents. Not a single S2S model but a composable pipeline of best-in-class ASR (Parakeet), TTS (Magpie), and NMT models deployed as NIM microservices via NVIDIA Riva.

### Key Features

- **ASR**: Parakeet TDT 0.6B v2 (#1 on HuggingFace ASR leaderboard, 6.05% WER)
- **ASR multilingual**: Parakeet RNNT 1.1B (25 languages)
- **TTS**: Magpie TTS Multilingual (natural voices, 17+ languages)
- **TTS zero-shot**: Magpie TTS Zero-Shot (voice cloning from short sample)
- **Speech enhancement**: StudioVoice (noise removal, studio quality)
- **Translation**: Riva Translate (36 languages)
- Deployed as GPU-accelerated NIM microservices
- Available via NVIDIA AI Enterprise or self-hosted
- 50x faster inference than alternatives (Parakeet v2)

### ASR Models (Nemotron Speech / Parakeet)

| Model | Params | Languages | WER | Speed (RTFx) | NIM |
|-------|--------|-----------|-----|-------------|-----|
| Parakeet TDT 0.6B v2 | 600M | English | 6.05% | 3386x | HF only |
| Parakeet CTC 1.1B | 1.1B | English | ~6.5% | Fast | Yes |
| Parakeet RNNT 1.1B | 1.1B | 25 langs | ~7% | Fast | Yes |
| Parakeet CTC 0.6B | 600M | EN, ES | ~7% | Fastest | Yes |
| Canary 1B | 1B | 4 langs | ~7% | Fast | Yes |

### TTS Models (Magpie)

| Model | Languages | Voice Clone | Streaming | NIM |
|-------|-----------|-------------|-----------|-----|
| Magpie TTS Multilingual | 17+ | No (preset voices) | Yes | Yes |
| Magpie TTS Zero-Shot | EN+ | Yes (short sample) | Yes | API |
| Magpie TTS Flow | EN+ | Yes (short sample) | Yes | API |

### Setup (NIM API)

```bash
# Store NVIDIA API key
aidevops secret set NVIDIA_API_KEY

# Test ASR via NIM API
curl -X POST "https://integrate.api.nvidia.com/v1/asr" \
  -H "Authorization: Bearer ${NVIDIA_API_KEY}" \
  -H "Content-Type: multipart/form-data" \
  -F "file=@audio.wav" \
  -F "model=nvidia/parakeet-ctc-0_6b-asr"
```

### Setup (Self-Hosted NIM)

```bash
# Pull and run Parakeet ASR NIM container
docker run --gpus all -p 8000:8000 \
  nvcr.io/nim/nvidia/parakeet-ctc-0_6b-asr:latest

# Pull and run Magpie TTS NIM container
docker run --gpus all -p 8001:8001 \
  nvcr.io/nim/nvidia/magpie-tts-multilingual:latest
```

### Composable Voice Agent Pipeline

```text
Audio In -> [Parakeet ASR NIM] -> Text -> [LLM (Claude/GPT/Nemotron)] -> Text -> [Magpie TTS NIM] -> Audio Out
                                                                                        |
                                                                            [StudioVoice NIM] (optional enhancement)
```

This cascaded approach gives full control over each component. Use any LLM in the middle (Claude, GPT-4o, Llama, Nemotron).

### Via Pipecat

Pipecat does not have a native NVIDIA Riva integration yet, but you can use the Riva gRPC API as a custom service or use the NIM REST endpoints.

### Requirements

- NVIDIA GPU (A100/H100 recommended for NIM self-hosting)
- Docker with NVIDIA Container Toolkit
- NVIDIA AI Enterprise license (for production NIM)
- Or use free API endpoints at https://build.nvidia.com/explore/speech

### Docs

- NVIDIA NIM Speech: https://build.nvidia.com/explore/speech
- Parakeet v2: https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- Riva documentation: https://docs.nvidia.com/deeplearning/riva/

## Deployment Patterns

### Pattern 1: Browser Voice Agent (WebRTC)

Best for: Customer-facing web apps, support chatbots.

```text
Browser (WebRTC) <-> OpenAI Realtime API (or Pipecat + Daily.co)
```

- Use OpenAI Agents SDK or Pipecat with SmallWebRTCTransport
- Client-side ephemeral keys for security
- No server infrastructure needed for OpenAI Realtime

### Pattern 2: Phone Bot (SIP/Twilio)

Best for: Call centers, IVR replacement, appointment booking.

```text
Phone (PSTN) -> Twilio -> SIP -> OpenAI Realtime API
                    or -> WebSocket -> Pipecat Pipeline
```

- OpenAI Realtime supports direct SIP connections
- Twilio Media Streams for WebSocket-based pipelines
- See `services/communications/twilio.md` for Twilio setup

### Pattern 3: Self-Hosted (Privacy/Compliance)

Best for: Healthcare, finance, government, air-gapped environments.

```text
Audio In -> [MiniCPM-o 2.6 on CUDA GPU] -> Audio Out
  or
Audio In -> [Parakeet NIM] -> [Local LLM] -> [Magpie NIM] -> Audio Out
```

- MiniCPM-o for single-model simplicity (Apache-2.0)
- NVIDIA Riva NIM for enterprise-grade composable pipeline
- No data leaves your infrastructure

### Pattern 4: Hybrid (Cloud LLM + Local Speech)

Best for: Balancing cost, latency, and quality.

```text
Audio In -> [Local Parakeet STT] -> Text -> [Cloud Claude/GPT] -> Text -> [Local Magpie TTS] -> Audio Out
```

- Speech processing stays local (fast, private)
- Only text hits the cloud LLM (smaller payload, lower cost)
- This is what the cascaded `speech-to-speech.md` pipeline does with `--llm open_api`

## Cost Comparison

| Solution | Approx. Cost/Min | Notes |
|----------|-------------------|-------|
| GPT-4o Realtime | ~$0.06 | Audio token pricing |
| Gemini 2.0 Live | ~$0.04 | Audio token pricing |
| MiniCPM-o (self-hosted) | GPU cost only | ~$0.01-0.03 on cloud GPU |
| NVIDIA Riva NIM (self-hosted) | GPU cost only | Enterprise license required |
| NVIDIA NIM API | Free tier available | Rate-limited |
| Cascaded (Groq STT + Claude + EdgeTTS) | ~$0.02 | Mix of free and paid |

## Framework Selection

| Framework | Best For | S2S Support | Complexity |
|-----------|----------|-------------|------------|
| **OpenAI Agents SDK** | Browser voice agents with GPT-4o | GPT-4o Realtime only | Low |
| **Pipecat** | Production multi-provider pipelines | OpenAI, Gemini, Nova Sonic | Medium |
| **voice-helper.sh** | Quick local voice interaction | No (cascaded only) | Low |
| **speech-to-speech.md** | Local/cloud cascaded pipeline | No (cascaded only) | Medium |
| **Custom WebSocket** | Full control, custom protocols | Any | High |

## Monitoring and Observability

For production voice agents, monitor:

- **Latency**: Time from user speech end to first audio response byte
- **Transcription accuracy**: Log STT output for quality review
- **Turn completion rate**: Percentage of turns that complete without interruption
- **Cost per conversation**: Track token/minute usage per provider

Use Pipecat's built-in metrics (`enable_metrics=True`) or instrument with OpenTelemetry.

## See Also

- `tools/voice/pipecat-opencode.md` - Pipecat pipeline setup for AI coding agents
- `tools/voice/speech-to-speech.md` - HuggingFace cascaded S2S pipeline
- `tools/voice/voice-ai-models.md` - Complete model comparison (TTS, STT, S2S)
- `tools/voice/voice-models.md` - TTS engine details and implementations
- `tools/infrastructure/cloud-gpu.md` - Cloud GPU deployment for self-hosted models
- `services/communications/twilio.md` - Phone integration
