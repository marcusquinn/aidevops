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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Cloud Voice Agents

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Deploy speech-to-speech voice agents in the cloud
- **Models**: GPT-4o Realtime (OpenAI), MiniCPM-o 2.6 (open weights), NVIDIA Nemotron Speech (Riva NIM)
- **Frameworks**: Pipecat (recommended), OpenAI Agents SDK, custom WebSocket/WebRTC
- **Related**: `tools/voice/speech-to-speech.md` (cascaded), `tools/voice/pipecat-opencode.md` (Pipecat bridge), `tools/voice/voice-ai-models.md` (model catalog), `tools/voice/voice-models.md` (TTS engines), `tools/infrastructure/cloud-gpu.md` (GPU deploy), `services/communications/twilio.md` (phone)

**When to use**: Production voice agents, phone bots, customer service, real-time conversational AI. For local/dev voice, use `voice-helper.sh talk`.

<!-- AI-CONTEXT-END -->

## Architecture

Native S2S (`Audio -> [S2S Model] -> Audio`): lower latency, less controllable. Examples: GPT-4o Realtime, MiniCPM-o omni.
Cascaded (`Audio -> [STT] -> [LLM] -> [TTS] -> Audio`): swappable components, easier to debug. Examples: Parakeet + Claude + Magpie via Riva.

## Model Comparison

| Model | Type | Latency | License | Languages | ~Cost/Min | Best For |
|-------|------|---------|---------|-----------|-----------|----------|
| GPT-4o Realtime | Cloud API | ~300ms | Proprietary | 50+ | $0.06 | Production cloud, lowest latency |
| MiniCPM-o 2.6 | Open weights | ~500ms | Apache-2.0 | EN, ZH | $0.01-0.03 | Self-hosted, privacy, multimodal |
| Nemotron Speech | NIM API/Self-host | ~200-400ms | Mixed | 25+ ASR, 17+ TTS | GPU/free tier | Enterprise, on-prem, NVIDIA GPUs |
| Gemini 2.0 Live | Cloud API | ~350ms | Proprietary | 40+ | $0.04 | Google ecosystem, multimodal |
| AWS Nova Sonic | Cloud API | ~600ms | Proprietary | 7 | -- | AWS ecosystem |
| Cascaded (Groq+Claude+Edge) | Mixed | Varies | Mixed | Many | $0.02 | Mix of free and paid |

## GPT-4o Realtime

Native S2S (GA 2025). WebRTC (browser), WebSocket (server), SIP (telephony). Model: `gpt-realtime` (GA) or `gpt-4o-realtime-preview` (legacy). Features: native audio I/O, emotion-aware, function calling, input transcription.

**Pricing**: Input ~$40/1M tokens, output ~$80/1M, cached ~$2.50/1M. **Voices**: alloy, ash, ballad, coral, echo, fable, marin, sage, shimmer, verse.

**Docs**: [API reference](https://platform.openai.com/docs/guides/realtime) | [Voice agents quickstart](https://openai.github.io/openai-agents-js/guides/voice-agents/quickstart/)

```bash
aidevops secret set OPENAI_API_KEY
```

### OpenAI Agents SDK (Browser)

```javascript
import { RealtimeAgent, RealtimeSession } from "@openai/agents/realtime";
const agent = new RealtimeAgent({
    name: "DevOps Assistant",
    instructions: "You are an AI DevOps assistant. Keep responses brief and spoken.",
});
const session = new RealtimeSession(agent);
await session.connect({ apiKey: "<client-api-key>" });
```

### Pipecat (Server)

```python
from pipecat.services.openai_realtime.llm import OpenAIRealtimeLLMService
s2s = OpenAIRealtimeLLMService(
    api_key=os.getenv("OPENAI_API_KEY"),
    model="gpt-4o-realtime-preview", voice="alloy",
)
pipeline = Pipeline([transport.input(), s2s, transport.output()])
```

### WebSocket (Direct)

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

## MiniCPM-o 2.6

Open-weight omni-modal (8B params, OpenBMB). Architecture: SigLip-400M + Whisper-medium-300M + ChatTTS-200M + Qwen2.5-7B. End-to-end speech (no separate STT/TTS), bilingual EN+ZH, voice cloning, emotion/speed/style control. Outperforms GPT-4o-realtime on audio benchmarks.

**Requirements**: Python 3.10+, PyTorch 2.3+, CUDA 8GB+ VRAM (16GB full omni), `transformers==4.44.2`. Apple Silicon: llama.cpp only (no MPS).

**Docs**: [GitHub](https://github.com/OpenBMB/MiniCPM-o) | [HuggingFace](https://huggingface.co/openbmb/MiniCPM-o-2_6) | [Ollama](https://ollama.com/openbmb/minicpm-o2.6)

```bash
pip install torch==2.3.1 torchaudio==2.3.1 transformers==4.44.2 \
    librosa soundfile vector-quantize-pytorch vocos decord moviepy
```

### Basic Speech Conversation

```python
import torch, librosa
from transformers import AutoModel, AutoTokenizer
model = AutoModel.from_pretrained(
    "openbmb/MiniCPM-o-2_6", trust_remote_code=True,
    attn_implementation="sdpa", torch_dtype=torch.bfloat16,
    init_vision=False, init_audio=True, init_tts=True,
)
model = model.eval().cuda()
tokenizer = AutoTokenizer.from_pretrained("openbmb/MiniCPM-o-2_6", trust_remote_code=True)
model.init_tts()

ref_audio, _ = librosa.load("reference_voice.wav", sr=16000, mono=True)
sys_prompt = model.get_sys_prompt(ref_audio=ref_audio, mode="audio_assistant", language="en")
user_audio, _ = librosa.load("user_question.wav", sr=16000, mono=True)
msgs = [sys_prompt, {"role": "user", "content": [user_audio]}]
res = model.chat(
    msgs=msgs, tokenizer=tokenizer, sampling=True, max_new_tokens=128,
    use_tts_template=True, generate_audio=True, temperature=0.3,
    output_audio_path="response.wav",
)
```

### Streaming (Low Latency)

```python
model.reset_session()
session_id = "voice-agent-001"
model.streaming_prefill(session_id=session_id, msgs=[sys_prompt], tokenizer=tokenizer)
for chunk in audio_chunks:
    model.streaming_prefill(
        session_id=session_id, tokenizer=tokenizer,
        msgs=[{"role": "user", "content": ["<unit>", chunk]}],
    )
for r in model.streaming_generate(
    session_id=session_id, tokenizer=tokenizer,
    temperature=0.5, generate_audio=True,
):
    play_audio(r.audio_wav, r.sampling_rate)
```

**Deployment**: HuggingFace Transformers (default), vLLM (high-throughput), llama.cpp (CPU/edge), `ollama run openbmb/minicpm-o2.6`, int4 quantized (`openbmb/MiniCPM-o-2_6-int4`), GGUF (16 quantization sizes).

## NVIDIA Nemotron Speech (Riva NIM)

Enterprise speech AI: composable ASR (Parakeet) + TTS (Magpie) + NMT as NIM microservices. Parakeet TDT 0.6B v2: #1 HF ASR leaderboard, 6.05% WER, 50x faster. Magpie TTS: 17+ languages, zero-shot voice cloning. StudioVoice noise removal. Riva Translate: 36 languages.

**Requirements**: NVIDIA GPU (A100/H100 for NIM self-hosting), Docker + NVIDIA Container Toolkit, AI Enterprise license (production). Free API: <https://build.nvidia.com/explore/speech>

**Docs**: [NVIDIA NIM Speech](https://build.nvidia.com/explore/speech) | [Parakeet v2](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2) | [Riva docs](https://docs.nvidia.com/deeplearning/riva/)

### Models

| Model | Type | Params | Languages | Key Spec | NIM |
|-------|------|--------|-----------|----------|-----|
| Parakeet TDT 0.6B v2 | ASR | 600M | English | 6.05% WER | HF only |
| Parakeet CTC 1.1B | ASR | 1.1B | English | ~6.5% WER | Yes |
| Parakeet RNNT 1.1B | ASR | 1.1B | 25 langs | ~7% WER | Yes |
| Parakeet CTC 0.6B | ASR | 600M | EN, ES | ~7% WER | Yes |
| Canary 1B | ASR | 1B | 4 langs | ~7% WER | Yes |
| Magpie Multilingual | TTS | -- | 17+ | Preset voices | Yes |
| Magpie Zero-Shot | TTS | -- | EN+ | Voice clone | API |
| Magpie Flow | TTS | -- | EN+ | Voice clone | API |

### Setup

```bash
aidevops secret set NVIDIA_API_KEY
# NIM API
curl -X POST "https://integrate.api.nvidia.com/v1/asr" \
  -H "Authorization: Bearer ${NVIDIA_API_KEY}" \
  -H "Content-Type: multipart/form-data" \
  -F "file=@audio.wav" -F "model=nvidia/parakeet-ctc-0_6b-asr"
# Self-hosted NIM
docker run --gpus all -p 8000:8000 nvcr.io/nim/nvidia/parakeet-ctc-0_6b-asr:latest
docker run --gpus all -p 8001:8001 nvcr.io/nim/nvidia/magpie-tts-multilingual:latest
```

### Composable Pipeline

`Audio -> [Parakeet ASR] -> Text -> [Any LLM] -> Text -> [Magpie TTS] -> Audio` (optional StudioVoice enhancement). Pipecat lacks native Riva integration — use Riva gRPC API or NIM REST endpoints.

## Deployment Patterns

| Pattern | Best For | Architecture |
|---------|----------|-------------|
| Browser (WebRTC) | Customer-facing web | Browser <-> OpenAI Realtime API (or Pipecat + Daily.co). Client-side ephemeral keys. |
| Phone Bot (SIP/Twilio) | Call centers, IVR | Phone -> Twilio -> SIP -> OpenAI Realtime, or WebSocket -> Pipecat. See `services/communications/twilio.md`. |
| Self-Hosted | Healthcare, finance, air-gapped | MiniCPM-o (Apache-2.0) or Parakeet+LLM+Magpie NIM. No data leaves infrastructure. |
| Hybrid | Cost/latency balance | Local STT -> Cloud LLM -> Local TTS. Only text hits cloud. See `speech-to-speech.md`. |

## Framework Selection

| Framework | Best For | S2S Support | Complexity |
|-----------|----------|-------------|------------|
| **OpenAI Agents SDK** | Browser voice with GPT-4o | GPT-4o Realtime only | Low |
| **Pipecat** | Production multi-provider | OpenAI, Gemini, Nova Sonic | Medium |
| **voice-helper.sh** | Quick local voice | No (cascaded only) | Low |
| **speech-to-speech.md** | Local/cloud cascaded | No (cascaded only) | Medium |
| **Custom WebSocket** | Full control | Any | High |

## Monitoring

Key metrics: latency (speech end -> first audio byte), transcription accuracy, turn completion rate, cost per conversation. Use Pipecat metrics (`enable_metrics=True`) or OpenTelemetry.
