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
- **Languages**: 10 languages (zh/en/ja/ko/de/fr/ru/pt/es/it)
- **Latency**: 97ms streaming latency (first chunk)
- **Models**: 1.7B and 0.6B variants (CustomVoice, VoiceDesign, Base)
- **Install**: `pip install qwen-tts` or vLLM-Omni
- **Helper**: `voice-helper.sh talk --tts qwen3-tts` (integration with voice bridge)

**When to Use**: Read this when you need multi-language TTS with voice cloning (3s reference), custom voice control (9 speakers + instruction), or voice design (natural language persona description). Ideal for production voice agents, content creation, and accessibility applications.

<!-- AI-CONTEXT-END -->

## Architecture

Qwen3-TTS is a discrete multi-codebook language model TTS system:

```text
Text Input -> [Text Encoder] -> [Multi-Codebook LM] -> [Vocoder] -> Audio Output
                                        |
                                   [Voice Prompt]
                                   (3s reference OR
                                    speaker ID OR
                                    persona description)
```

Three model variants:

1. **Base**: Standard TTS with 9 preset speakers
2. **CustomVoice**: Voice cloning from 3-second reference audio + instruction control
3. **VoiceDesign**: Voice generation from natural language persona description

## Model Selection

| Model | Size | Use Case | VRAM |
|-------|------|----------|------|
| Qwen3-TTS-1.7B-Base | 1.7B | High quality, 9 preset speakers | ~4GB |
| Qwen3-TTS-0.6B-Base | 0.6B | Lightweight, 9 preset speakers | ~2GB |
| Qwen3-TTS-1.7B-CustomVoice | 1.7B | Voice cloning + instruction control | ~4GB |
| Qwen3-TTS-0.6B-CustomVoice | 0.6B | Lightweight voice cloning | ~2GB |
| Qwen3-TTS-1.7B-VoiceDesign | 1.7B | Persona-based voice generation | ~4GB |
| Qwen3-TTS-0.6B-VoiceDesign | 0.6B | Lightweight voice design | ~2GB |

**Recommendation**: Start with 0.6B-CustomVoice for development (lower VRAM), upgrade to 1.7B for production quality.

## Setup

### Via Python Package (Recommended)

```bash
# Install qwen-tts package
pip install qwen-tts

# Or with uv (faster)
uv pip install qwen-tts
```

### Via vLLM-Omni (For Production Serving)

```bash
# Install vLLM-Omni
pip install vllm-omni

# Start server
vllm serve Qwen/Qwen3-TTS-1.7B-CustomVoice \
    --task tts \
    --dtype auto \
    --max-model-len 2048
```

## Usage

### Base Model (Preset Speakers)

```python
from qwen_tts import QwenTTS

# Initialize model
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-Base")

# Generate speech with speaker ID (0-8)
audio = tts.synthesize(
    text="Hello, I am your AI DevOps assistant.",
    speaker_id=0,  # 0-8 for different voices
    language="en"
)

# Save to file
tts.save_audio(audio, "output.wav")
```

### CustomVoice (Voice Cloning)

```python
from qwen_tts import QwenTTS

# Initialize CustomVoice model
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-CustomVoice")

# Clone voice from 3-second reference
audio = tts.synthesize(
    text="This is a cloned voice speaking.",
    reference_audio="path/to/reference.wav",  # 3s+ reference
    instruction="Speak in a calm, professional tone",  # Optional control
    language="en"
)
```

### VoiceDesign (Persona-Based)

```python
from qwen_tts import QwenTTS

# Initialize VoiceDesign model
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-VoiceDesign")

# Generate voice from persona description
audio = tts.synthesize(
    text="Welcome to the AI DevOps framework.",
    persona="A friendly female voice, mid-30s, British accent, warm and professional",
    language="en"
)
```

### Streaming (Low Latency)

```python
from qwen_tts import QwenTTS

tts = QwenTTS(model="Qwen/Qwen3-TTS-0.6B-CustomVoice", streaming=True)

# Stream audio chunks (97ms first chunk latency)
for chunk in tts.synthesize_stream(
    text="This is a streaming example with ultra-low latency.",
    speaker_id=0,
    language="en"
):
    # Play chunk immediately (e.g., via sounddevice)
    play_audio(chunk)
```

## Multi-Language Support

Qwen3-TTS supports 10 languages with automatic language detection:

| Language | Code | Notes |
|----------|------|-------|
| Chinese | `zh` | Mandarin |
| English | `en` | US/UK |
| Japanese | `ja` | |
| Korean | `ko` | |
| German | `de` | |
| French | `fr` | |
| Russian | `ru` | |
| Portuguese | `pt` | BR/PT |
| Spanish | `es` | ES/LATAM |
| Italian | `it` | |

```python
# Auto-detect language
audio = tts.synthesize(text="Bonjour, je suis votre assistant IA.")

# Or specify explicitly
audio = tts.synthesize(text="Bonjour, je suis votre assistant IA.", language="fr")
```

## Integration with Voice Bridge

Add Qwen3-TTS to the aidevops voice bridge:

```bash
# Use Qwen3-TTS as TTS engine
voice-helper.sh talk whisper-mlx qwen3-tts

# With custom voice
voice-helper.sh talk whisper-mlx qwen3-tts --voice-ref path/to/reference.wav

# With persona
voice-helper.sh talk whisper-mlx qwen3-tts --persona "Friendly British female, professional"
```

See `voice-helper.sh` for full integration details.

## Performance Optimization

### GPU Acceleration

```python
# Use CUDA for faster inference
tts = QwenTTS(model="Qwen/Qwen3-TTS-1.7B-CustomVoice", device="cuda")
```

### Batch Processing

```python
# Process multiple texts in parallel
texts = ["First sentence.", "Second sentence.", "Third sentence."]
audios = tts.batch_synthesize(texts, speaker_id=0, language="en")
```

### Model Caching

```python
# Cache model for faster subsequent loads
tts = QwenTTS(
    model="Qwen/Qwen3-TTS-1.7B-CustomVoice",
    cache_dir="~/.cache/qwen-tts"
)
```

## Voice Cloning Best Practices

1. **Reference Audio Quality**:
   - 3+ seconds of clean speech
   - Single speaker, no background noise
   - Clear pronunciation
   - Sample rate: 16kHz or higher

2. **Instruction Control**:
   - Use natural language: "Speak slowly and clearly"
   - Emotion: "Sound excited and energetic"
   - Tone: "Use a professional, calm tone"
   - Accent: "British accent" or "American accent"

3. **Persona Design**:
   - Be specific: age, gender, accent, personality
   - Example: "A cheerful young woman in her 20s, American accent, enthusiastic and friendly"

## Deployment Modes

### Local (Development)

```bash
# Run locally with Python
python your_tts_script.py
```

### Server (Production)

```bash
# Start vLLM-Omni server
vllm serve Qwen/Qwen3-TTS-1.7B-CustomVoice \
    --task tts \
    --host 0.0.0.0 \
    --port 8000 \
    --dtype auto

# Client request
curl -X POST http://localhost:8000/v1/audio/speech \
    -H "Content-Type: application/json" \
    -d '{
        "text": "Hello world",
        "speaker_id": 0,
        "language": "en"
    }' \
    --output output.wav
```

### Docker

```dockerfile
FROM python:3.10-slim

RUN pip install qwen-tts

COPY your_script.py /app/
WORKDIR /app

CMD ["python", "your_script.py"]
```

## Cloud GPU Providers

For production deployment when local GPU is insufficient, see the shared **[Cloud GPU Deployment Guide](../infrastructure/cloud-gpu.md)** for:

- Provider comparison (RunPod, Vast.ai, Lambda, NVIDIA Cloud)
- GPU selection by VRAM requirements
- SSH setup, Docker deployment, model caching
- Cost optimization strategies

Quick reference for Qwen3-TTS GPU needs: 2GB VRAM minimum (0.6B models), 4GB recommended (1.7B models). See the guide's VRAM requirements table for details.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| `ModuleNotFoundError: qwen_tts` | Run `pip install qwen-tts` |
| High latency | Use streaming mode: `streaming=True` |
| OOM on GPU | Use 0.6B model or CPU: `device="cpu"` |
| Poor voice clone quality | Ensure 3+ seconds of clean reference audio |
| Accent not matching | Use instruction control: `instruction="British accent"` |

## See Also

- `tools/voice/speech-to-speech.md` - Full S2S pipeline (VAD, STT, LLM, TTS)
- `tools/voice/voice-ai-models.md` - Complete model comparison (TTS, STT, S2S)
- `tools/voice/cloud-voice-agents.md` - Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/pipecat-opencode.md` - Pipecat real-time voice pipeline
- `tools/infrastructure/cloud-gpu.md` - Cloud GPU deployment guide
- `services/communications/twilio.md` - Phone integration
- `tools/video/remotion.md` - Video narration
