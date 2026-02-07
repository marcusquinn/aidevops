---
description: Audio/video transcription with local and cloud models
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Audio/Video Transcription

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Transcribe audio/video from YouTube, URLs, or local files
- **Helper**: `transcription-helper.sh [transcribe|models|configure] [options]`
- **Default model**: Whisper Large v3 Turbo (best speed/accuracy tradeoff)
- **Dependencies**: `yt-dlp` (YouTube), `ffmpeg` (audio extraction), `faster-whisper` or `whisper.cpp` (local)

**Quick Commands**:

```bash
# Transcribe YouTube video
transcription-helper.sh transcribe "https://youtu.be/dQw4w9WgXcQ"

# Transcribe local file
transcription-helper.sh transcribe recording.mp3

# Transcribe with specific model
transcription-helper.sh transcribe recording.mp3 --model large-v3-turbo

# List available models
transcription-helper.sh models
```

<!-- AI-CONTEXT-END -->

## Input Sources

| Source | Detection | Extraction |
|--------|-----------|------------|
| YouTube URL | `youtu.be/` or `youtube.com/watch` | `yt-dlp -x --audio-format wav` |
| Direct media URL | HTTP(S) with media extension | `curl` + `ffmpeg` if video |
| Local audio | `.wav`, `.mp3`, `.flac`, `.ogg`, `.m4a` | Direct input |
| Local video | `.mp4`, `.mkv`, `.webm`, `.avi` | `ffmpeg -i input -vn -acodec pcm_s16le` |

## Local Models (Whisper Family)

### via faster-whisper (Recommended)

CTranslate2-based, 4x faster than OpenAI Whisper with same accuracy.
See `voice-bridge.py:99-115` for the repo's `FasterWhisperSTT` implementation.

```bash
pip install faster-whisper
```

Official usage: https://github.com/SYSTRAN/faster-whisper#usage

### via whisper.cpp (C++ native)

Optimized for Apple Silicon and CPU inference.

```bash
# Build from source (no Homebrew formula)
git clone https://github.com/ggml-org/whisper.cpp.git
cd whisper.cpp && cmake -B build && cmake --build build -j --config Release

# Download model
sh ./models/download-ggml-model.sh large-v3-turbo

# Transcribe
./build/bin/whisper-cli -f audio.wav -otxt -osrt
```

### Model Comparison

| Model | Size | Speed | Accuracy | Notes |
|-------|------|-------|----------|-------|
| Tiny | 75MB | 9.5 | 6.0-6.5 | Draft/preview only |
| Base | 142MB | 8.5 | 7.2-7.5 | Quick transcription |
| Small | 461MB | 7.0 | 8.5 | Good balance |
| Medium | 1.5GB | 5.0 | 9.0 | Solid quality |
| Large v2 | 2.9GB | 3.0 | 9.6 | High quality |
| Large v3 | 2.9GB | 3.0 | 9.8 | Best quality |
| **Large v3 Turbo** | **1.5GB** | **7.5** | **9.7** | **Recommended default** |
| Large v3 Turbo Q | 547MB | 7.5 | 9.5 | Quantized, smaller |

### Other Local Models

| Model | Size | Speed | Accuracy | Notes |
|-------|------|-------|----------|-------|
| NVIDIA Parakeet V2 | 474MB | 9.9 | 9.4 | English-only, fastest |
| NVIDIA Parakeet V3 | 494MB | 9.9 | 9.4 | Multilingual, experimental |
| Apple Speech | Built-in | 9.0 | 9.0 | macOS 26+, on-device |

## Cloud APIs

| Provider | Model | Accuracy | Speed | Cost |
|----------|-------|----------|-------|------|
| **Groq** | Whisper Large v3 Turbo | 9.6 | Lightning | Free tier available |
| **ElevenLabs** | Scribe v2 | 9.9 | Fast | Pay per minute |
| **ElevenLabs** | Scribe v1 | 9.8 | Fast | Pay per minute |
| **Mistral** | Voxtral Mini | 9.7 | Fast | Pay per token |
| **Deepgram** | Nova-2 | 9.5 | Real-time | Pay per minute |
| **Deepgram** | Nova-3 Medical | 9.6 | Real-time | English-only, clinical |
| **OpenAI** | Whisper API | 9.5 | Fast | $0.006/min |
| **Google** | Gemini 3 Pro | 9.7 | Fast | Multimodal input |
| **Google** | Gemini 3 Flash | 9.5 | Fastest | Low latency |
| **Soniox** | stt-async-v3 | 9.6 | Async | Batch processing |

### Groq (Fastest Cloud)

```bash
curl https://api.groq.com/openai/v1/audio/transcriptions \
  -H "Authorization: Bearer ${GROQ_API_KEY}" \
  -H "Content-Type: multipart/form-data" \
  -F "file=@audio.wav" \
  -F "model=whisper-large-v3" \
  -F "response_format=verbose_json"
```

Docs: https://console.groq.com/docs/speech-text

### OpenAI Whisper API

```bash
curl https://api.openai.com/v1/audio/transcriptions \
  -H "Authorization: Bearer ${OPENAI_API_KEY}" \
  -F "file=@audio.wav" \
  -F "model=whisper-1" \
  -F "response_format=srt"
```

Docs: https://platform.openai.com/docs/api-reference/audio/createTranscription

### ElevenLabs Scribe

```bash
curl -X POST "https://api.elevenlabs.io/v1/speech-to-text" \
  -H "xi-api-key: ${ELEVENLABS_API_KEY}" \
  -F "file=@audio.wav" \
  -F "model_id=scribe_v1"
```

Docs: https://elevenlabs.io/docs/api-reference/speech-to-text

## Output Formats

| Format | Extension | Use Case |
|--------|-----------|----------|
| Plain text | `.txt` | Reading, search indexing |
| SRT | `.srt` | Video subtitles |
| VTT | `.vtt` | Web video subtitles |
| JSON | `.json` | Programmatic access, timestamps |
| TSV | `.tsv` | Spreadsheet analysis |

## Transcription Pipeline

```text
Input Source
    │
    ├── YouTube URL ──→ yt-dlp -x ──→ audio.wav
    ├── Video URL ────→ curl + ffmpeg ──→ audio.wav
    ├── Video file ───→ ffmpeg -vn ──→ audio.wav
    └── Audio file ───→ (direct) ──→ audio.wav
                                        │
                                   Model Selection
                                        │
                              ┌─────────┴─────────┐
                              │                    │
                         Local Model          Cloud API
                     (faster-whisper)      (Groq/OpenAI/etc)
                              │                    │
                              └─────────┬──────────┘
                                        │
                                   Output Format
                                   (txt/srt/vtt/json)
```

## Dependencies

```bash
# Core
brew install yt-dlp ffmpeg    # macOS
apt install yt-dlp ffmpeg     # Ubuntu/Debian

# Local inference (pick one)
pip install faster-whisper     # Python (recommended)
# whisper.cpp: build from source (see above)
```

## Related

- `tools/voice/voice-models.md` - TTS models for speech generation
- `tools/voice/speech-to-speech.md` - Full voice pipeline
- `tools/content/summarize.md` - Can summarize transcribed content
- `voice-helper.sh` - CLI for voice operations
