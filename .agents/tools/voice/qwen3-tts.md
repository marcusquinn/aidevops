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

# Qwen3-TTS

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Source**: [QwenLM/Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS) (Apache-2.0)
- **Languages**: zh, en, ja, ko, de, fr, ru, pt, es, it (auto-detected)
- **Latency**: 97ms streaming first chunk
- **Models**: 1.7B (~4GB VRAM), 0.6B (~2GB) — Base (9 preset speakers), CustomVoice (clone from 3s ref + instruction), VoiceDesign (natural language persona)
- **Install**: `pip install qwen-tts` (library) | `pip install vllm-omni` (production server)
- **Not supported** by voice-bridge.py — use the Python API directly
- **When to Use**: Voice cloning, custom voice control, or voice design. Start with 0.6B-CustomVoice for dev; 1.7B for production.

<!-- AI-CONTEXT-END -->

## Setup

```bash
pip install qwen-tts            # Python package
pip install vllm-omni           # Production server
vllm serve Qwen/Qwen3-TTS-1.7B-CustomVoice --task tts --dtype auto --max-model-len 2048
```

## Usage

### Base (Preset Speakers)

```python
from qwen_tts import QwenTTS

tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-Base")
audio = tts.synthesize(text="Hello, I am your AI DevOps assistant.", speaker_id=0, language="en")
tts.save_audio(audio, "output.wav")
```

### CustomVoice (Voice Cloning)

Reference audio: 3+ seconds clean speech, single speaker, no background noise, 16kHz+. Instruction accepts natural language ("Speak slowly", "British accent").

```python
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-CustomVoice")
audio = tts.synthesize(
    text="This is a cloned voice speaking.",
    reference_audio="path/to/reference.wav",  # 3s+ clean, single speaker, 16kHz+
    instruction="Speak in a calm, professional tone",
    language="en"
)
```

### VoiceDesign (Persona-Based)

Be specific: age, gender, accent, personality.

```python
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-VoiceDesign")
audio = tts.synthesize(
    text="Welcome to the AI DevOps framework.",
    persona="A friendly female voice, mid-30s, British accent, warm and professional",
    language="en"
)
```

### Streaming & Performance

```python
# Streaming (97ms first-chunk latency)
tts = QwenTTS(model="Qwen/Qwen3-TTS-0.6B-CustomVoice", streaming=True)
for chunk in tts.synthesize_stream(text="Streaming output.", speaker_id=0, language="en"):
    play_audio(chunk)

# GPU acceleration & batch processing
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-CustomVoice", device="cuda")
audios = tts.batch_synthesize(["First.", "Second.", "Third."], speaker_id=0, language="en")
```

## Production Deployment

```bash
vllm serve Qwen/Qwen3-TTS-1.7B-CustomVoice --task tts --host 0.0.0.0 --port 8000 --dtype auto

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
| High latency | Enable streaming: `streaming=True` |
| OOM on GPU | Use 0.6B model or `device="cpu"` |
| Poor clone quality | 3+ seconds clean reference audio required |
| Accent mismatch | Use `instruction="British accent"` |

## See Also

- `tools/voice/speech-to-speech.md` — S2S pipeline (VAD, STT, LLM, TTS)
- `tools/voice/voice-ai-models.md` — Model comparison (TTS, STT, S2S)
- `tools/voice/cloud-voice-agents.md` — Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/pipecat-opencode.md` — Pipecat real-time voice pipeline
- `tools/infrastructure/cloud-gpu.md` — Cloud GPU deployment guide
- `services/communications/twilio.md` — Phone integration
- `tools/video/remotion.md` — Video narration
