---
description: "Qwen3-TTS - discrete multi-codebook LM TTS with 10 languages, voice cloning, voice design, and 97ms streaming latency"
mode: subagent
upstream_url: https://github.com/QwenLM/Qwen3-TTS
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

# Qwen3-TTS

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Source**: [QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) (Apache-2.0)
- **Languages**: zh, en, ja, ko, de, fr, ru, pt, es, it (auto-detected)
- **Latency**: 97ms streaming first chunk
- **Models**: 1.7B (~4GB VRAM), 0.6B (~2GB) — Base (voice clone from 3s ref audio), CustomVoice (9 preset speakers + instruction control), VoiceDesign (natural language persona)
- **Class**: `Qwen3TTSModel` from `qwen_tts` — methods: `generate_custom_voice()`, `generate_voice_clone()`, `generate_voice_design()`
- **Install**: `pip install qwen-tts` (library) | `pip install vllm-omni` (production server)
- **Not supported** by voice-bridge.py — use the Python API directly
- **When to Use**: Voice cloning, custom voice control, or voice design. Start with 0.6B-CustomVoice for dev; 1.7B for production.

<!-- AI-CONTEXT-END -->

## Setup

```bash
pip install qwen-tts            # Python package
pip install vllm-omni           # Production server
vllm serve Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice --task tts --dtype auto --max-model-len 2048
```

## Usage

### CustomVoice (Preset Speakers + Instruction)

9 preset speakers (Vivian, Serena, Ryan, Aiden, etc.). Optional `instruct` for tone/emotion control.

```python
import torch, soundfile as sf
from qwen_tts import Qwen3TTSModel

model = Qwen3TTSModel.from_pretrained("Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice",
    device_map="cuda:0", dtype=torch.bfloat16)
wavs, sr = model.generate_custom_voice(
    text="Hello, I am your AI DevOps assistant.",
    speaker="Ryan", language="English",
    instruct="Speak in a calm, professional tone"  # optional
)
sf.write("output.wav", wavs[0], sr)
```

### Base (Voice Clone)

Reference audio: 3+ seconds clean speech, single speaker, no background noise, 16kHz+.

```python
model = Qwen3TTSModel.from_pretrained("Qwen/Qwen3-TTS-12Hz-1.7B-Base",
    device_map="cuda:0", dtype=torch.bfloat16)
wavs, sr = model.generate_voice_clone(
    text="This is a cloned voice speaking.",
    language="English",
    ref_audio="path/to/reference.wav",  # 3s+ clean, single speaker, 16kHz+
    ref_text="Transcript of the reference audio."
)
sf.write("output_clone.wav", wavs[0], sr)
```

### VoiceDesign (Persona-Based)

Be specific: age, gender, accent, personality.

```python
model = Qwen3TTSModel.from_pretrained("Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign",
    device_map="cuda:0", dtype=torch.bfloat16)
wavs, sr = model.generate_voice_design(
    text="Welcome to the AI DevOps framework.",
    language="English",
    instruct="A friendly female voice, mid-30s, British accent, warm and professional"
)
sf.write("output_design.wav", wavs[0], sr)
```

### Batch & Streaming

```python
# Batch inference
wavs, sr = model.generate_custom_voice(
    text=["First.", "Second.", "Third."],
    speaker=["Ryan", "Ryan", "Ryan"],
    language=["English", "English", "English"]
)

# Streaming (97ms first-chunk latency) — pass non_streaming_mode=False
wavs, sr = model.generate_custom_voice(
    text="Streaming output.", speaker="Ryan", language="English",
    non_streaming_mode=False
)
```

## Production Deployment

```bash
vllm serve Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice --task tts --host 0.0.0.0 --port 8000 --dtype auto

curl -X POST http://localhost:8000/v1/audio/speech \
    -H "Content-Type: application/json" \
    -d '{"text": "Hello world", "speaker_id": 0, "language": "en"}' \
    --output output.wav
```

Cloud GPU (RunPod, Vast.ai, Lambda, NVIDIA Cloud): see **[Cloud GPU Guide](../infrastructure/cloud-gpu.md)**.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ModuleNotFoundError: qwen_tts` | `pip install qwen-tts` |
| High latency | Enable streaming: `non_streaming_mode=False` |
| OOM on GPU | Use 0.6B model or `device_map="cpu"` |
| Poor clone quality | 3+ seconds clean reference audio required |
| Accent mismatch | Use `instruct="British accent"` |

## See Also

- `tools/voice/speech-to-speech.md` — S2S pipeline (VAD, STT, LLM, TTS)
- `tools/voice/voice-ai-models.md` — Model comparison (TTS, STT, S2S)
- `tools/voice/cloud-voice-agents.md` — Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/pipecat-opencode.md` — Pipecat real-time voice pipeline
- `tools/infrastructure/cloud-gpu.md` — Cloud GPU deployment guide
- `services/communications/twilio.md` — Phone integration
- `tools/video/remotion.md` — Video narration
