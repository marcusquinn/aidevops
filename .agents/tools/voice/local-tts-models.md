---
description: Local open-weight TTS models - Kokoro, Dia, F5-TTS, Bark, Coqui, Piper
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

# Local Open-Weight TTS Models

Reference for local TTS models available for standalone inference. For Qwen3-TTS (recommended for quality + multilingual), see `tools/voice/qwen3-tts.md`. For voice bridge engines (EdgeTTS, macOS Say, FacebookMMS), see `tools/voice/voice-models.md`.

## Kokoro (Recommended for Lightweight + Fast)

82M parameter open-weight TTS. 5.6k stars, Apache-2.0.

- **Languages**: American/British English, Spanish, French, Hindi, Italian, Japanese, Brazilian Portuguese, Mandarin
- **Features**: Fast inference, multiple voice presets, MPS (Apple Silicon)
- **Requires**: `espeak-ng`, Python 3.9+ — **Install**: `pip install kokoro`

```python
from kokoro import KPipeline
import soundfile as sf

pipeline = KPipeline(lang_code='a')  # 'a' = American English
for i, (gs, ps, audio) in enumerate(pipeline("Hello world!", voice='af_heart')):
    sf.write(f'{i}.wav', audio, 24000)
```

Docs: https://github.com/hexgrad/kokoro

## Dia (Recommended for Dialogue)

1.6B parameter dialogue TTS by Nari Labs. 19.1k stars, Apache-2.0. English only (~4.4GB VRAM).

- **Features**: Multi-speaker in one pass (`[S1]`/`[S2]` tags), non-verbal sounds (laughs, coughs, sighs), voice cloning via audio prompt
- **Requires**: CUDA GPU, PyTorch 2.0+ — **Install**: `pip install git+https://github.com/nari-labs/dia.git`
- **Dia2**: https://github.com/nari-labs/dia2

```python
from dia.model import Dia

model = Dia.from_pretrained("nari-labs/Dia-1.6B-0626")
output = model.generate(
    "[S1] Hey, how are you doing? [S2] I'm great, thanks for asking! (laughs)"
)
```

Docs: https://github.com/nari-labs/dia

## F5-TTS (Recommended for Voice Cloning)

Flow-matching TTS with zero-shot voice cloning. 14.1k stars, MIT (code), CC-BY-NC (weights).

- **Languages**: Chinese, English (base), extensible via fine-tuning
- **Features**: Zero-shot cloning from short reference audio, sway sampling, multi-speaker, Gradio UI, CLI, Docker, TensorRT-LLM
- **Requires**: CUDA/ROCm/XPU/MPS, Python 3.10+ — **Install**: `pip install f5-tts`

```bash
f5-tts_infer-cli \
  --model F5TTS_v1_Base \
  --ref_audio "reference.wav" \
  --ref_text "Transcript of reference audio." \
  --gen_text "Text to generate in the cloned voice."
```

Docs: https://github.com/SWivid/F5-TTS

## Bark (Suno)

Transformer-based TTS with non-speech generation. 39k+ stars, MIT. **No active development since 2023.**

- **Languages**: 13 languages including English, Chinese, French, German, Hindi, Japanese, Spanish
- **Features**: Non-speech sounds (music, laughter, background noise), speaker presets
- **Install**: `pip install git+https://github.com/suno-ai/bark.git`

Docs: https://github.com/suno-ai/bark

## Coqui TTS

Multi-model TTS toolkit. 44k+ stars, MPL-2.0. **Company shut down late 2023; community-maintained.**

- **Features**: 20+ models (Tacotron2, VITS, YourTTS, Bark, etc.), voice cloning, multi-speaker, training
- **Install**: `pip install TTS`

Docs: https://github.com/coqui-ai/TTS

## Piper TTS (Archived)

Fast local neural TTS. 10.5k stars, MIT. **Archived Oct 2025** — active fork: https://github.com/OHF-Voice/piper1-gpl (GPL).

- **Features**: Lightweight C++ binary, 100+ voices, CPU-friendly; best for embedded/IoT, Home Assistant

Docs: https://github.com/rhasspy/piper (archived)

## Installation

```bash
pip install kokoro                                    # Kokoro 82M
pip install f5-tts                                    # F5-TTS
pip install TTS                                       # Coqui TTS
pip install git+https://github.com/nari-labs/dia.git  # Dia
pip install git+https://github.com/suno-ai/bark.git   # Bark

# System dependencies (macOS)
brew install espeak-ng  # Required by Kokoro
# Linux: apt install espeak-ng
```

## Related

- `tools/voice/qwen3-tts.md` - Qwen3-TTS (recommended for quality + multilingual)
- `tools/voice/voice-models.md` - Voice bridge engines and model selection index
- `tools/voice/voice-ai-models.md` - Complete model comparison (TTS, STT, S2S)
- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD+STT+LLM+TTS)
