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
- **Purpose**: Multi-language TTS with voice cloning, voice design, and ultra-low latency
- **Languages**: zh, en, ja, ko, de, fr, ru, pt, es, it (auto-detected)
- **Latency**: 97ms streaming (first chunk)
- **Models**: 1.7B (~4GB VRAM) and 0.6B (~2GB) in Base, CustomVoice, VoiceDesign variants
- **Install**: `pip install qwen-tts` or `pip install vllm-omni` (production serving)
- **Helper**: `voice-helper.sh talk whisper-mlx qwen3-tts` (voice bridge integration)

**When to Use**: Multi-language TTS with voice cloning (3s reference), custom voice control (9 speakers + instruction), or voice design (natural language persona). Ideal for voice agents, content creation, and accessibility.

<!-- AI-CONTEXT-END -->

## Models

Three variants, each in 1.7B (quality) and 0.6B (lightweight):

| Variant | Capability |
|---------|-----------|
| **Base** | 9 preset speakers, standard TTS |
| **CustomVoice** | Voice cloning from 3s reference + instruction control |
| **VoiceDesign** | Voice generation from natural language persona description |

**Start with 0.6B-CustomVoice** for development; upgrade to 1.7B for production.

## Setup

```bash
# Python package (recommended)
pip install qwen-tts

# Production server (vLLM-Omni)
pip install vllm-omni
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

```python
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-CustomVoice")
audio = tts.synthesize(
    text="This is a cloned voice speaking.",
    reference_audio="path/to/reference.wav",  # 3s+ clean speech, single speaker, 16kHz+
    instruction="Speak in a calm, professional tone",
    language="en"
)
```

### VoiceDesign (Persona-Based)

```python
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-VoiceDesign")
audio = tts.synthesize(
    text="Welcome to the AI DevOps framework.",
    persona="A friendly female voice, mid-30s, British accent, warm and professional",
    language="en"
)
```

### Streaming

```python
tts = QwenTTS(model="Qwen/Qwen3-TTS-0.6B-CustomVoice", streaming=True)
for chunk in tts.synthesize_stream(text="Streaming with 97ms first-chunk latency.", speaker_id=0, language="en"):
    play_audio(chunk)
```

## Voice Bridge Integration

```bash
voice-helper.sh talk whisper-mlx qwen3-tts                              # Default
voice-helper.sh talk whisper-mlx qwen3-tts path/to/reference.wav        # Custom voice
voice-helper.sh talk whisper-mlx qwen3-tts path/to/reference.wav opencode/claude-sonnet-4-6  # Custom voice + model
```

> Positional args: `stt tts voice model`. Named flags (`--voice-ref`, `--persona`) not supported.
> Voice design (persona descriptions) must use the Python API directly.

## Performance

```python
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-CustomVoice", device="cuda")  # GPU acceleration
tts = QwenTTS(model="...", cache_dir="~/.cache/qwen-tts")               # Model caching

# Batch processing
audios = tts.batch_synthesize(["First.", "Second.", "Third."], speaker_id=0, language="en")
```

## Voice Cloning Tips

- **Reference audio**: 3+ seconds clean speech, single speaker, no background noise, 16kHz+
- **Instruction control**: natural language — "Speak slowly", "Sound excited", "British accent"
- **Persona design**: be specific — age, gender, accent, personality (e.g., "A cheerful young woman in her 20s, American accent, enthusiastic")

## Production Deployment

```bash
# vLLM-Omni server
vllm serve Qwen/Qwen3-TTS-1.7B-CustomVoice --task tts --host 0.0.0.0 --port 8000 --dtype auto

# Client
curl -X POST http://localhost:8000/v1/audio/speech \
    -H "Content-Type: application/json" \
    -d '{"text": "Hello world", "speaker_id": 0, "language": "en"}' \
    --output output.wav
```

For cloud GPU deployment (RunPod, Vast.ai, Lambda, NVIDIA Cloud), see **[Cloud GPU Guide](../infrastructure/cloud-gpu.md)**. VRAM: 2GB min (0.6B), 4GB recommended (1.7B).

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ModuleNotFoundError: qwen_tts` | `pip install qwen-tts` |
| High latency | Use streaming: `streaming=True` |
| OOM on GPU | Use 0.6B model or `device="cpu"` |
| Poor voice clone quality | Ensure 3+ seconds clean reference audio |
| Accent not matching | Use instruction: `instruction="British accent"` |

## See Also

- `tools/voice/speech-to-speech.md` — Full S2S pipeline (VAD, STT, LLM, TTS)
- `tools/voice/voice-ai-models.md` — Complete model comparison (TTS, STT, S2S)
- `tools/voice/cloud-voice-agents.md` — Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/pipecat-opencode.md` — Pipecat real-time voice pipeline
- `tools/infrastructure/cloud-gpu.md` — Cloud GPU deployment guide
- `services/communications/twilio.md` — Phone integration
- `tools/video/remotion.md` — Video narration
