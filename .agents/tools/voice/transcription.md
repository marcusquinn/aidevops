---
description: Audio/video transcription with local and cloud models
mode: subagent
tools:
  read: true
  bash: true
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

Optimized for Apple Silicon and CPU inference. Build from source: https://github.com/ggml-org/whisper.cpp

```bash
./build/bin/whisper-cli -m models/ggml-large-v3-turbo.bin -f audio.wav -otxt -osrt
```

### Model Comparison

| Model | Size | Speed | Accuracy | Notes |
|-------|------|-------|----------|-------|
| Tiny | 75MB | 9.5 | 6.0 | Draft/preview only |
| Base | 142MB | 8.5 | 7.3 | Quick transcription |
| Small | 461MB | 7.0 | 8.5 | Good balance, multilingual |
| Medium | 1.5GB | 5.0 | 9.0 | Solid quality |
| Large v3 | 2.9GB | 3.0 | 9.8 | Best quality |
| **Large v3 Turbo** | **1.5GB** | **7.5** | **9.7** | **Recommended default** |

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

Store API keys via `aidevops secret set <PROVIDER>_API_KEY`. All cloud APIs accept standard multipart file upload. Example (Groq):

```bash
curl https://api.groq.com/openai/v1/audio/transcriptions \
  -H "Authorization: Bearer ${GROQ_API_KEY}" \
  -H "Content-Type: multipart/form-data" \
  -F "file=@audio.wav" \
  -F "model=whisper-large-v3" \
  -F "response_format=verbose_json"
```

## Model Selection Guidance

| Priority | Local | Cloud |
|----------|-------|-------|
| **Best accuracy** | Large v3 (9.8) | ElevenLabs Scribe v2 (9.9) |
| **Best speed** | Parakeet V2 (English) | Groq Whisper (free tier) |
| **Best balance** | **Large v3 Turbo** (default) | Groq or Gemini Flash |
| **Lowest cost** | Any local model ($0) | Groq free tier, then OpenAI ($0.006/min) |
| **Offline/private** | faster-whisper or whisper.cpp | N/A |
| **Multilingual** | Large v3 or Small | Voxtral Mini or Gemini Pro |

**Decision flow**: Local first (free, private) unless file is very long (use Groq async) or accuracy is critical (use Scribe v2).

## Output Formats

| Format | Use Case |
|--------|----------|
| `.txt` | Reading, search indexing |
| `.srt` | Video subtitles (most compatible) |
| `.vtt` | Web video subtitles |
| `.json` | Programmatic access, timestamps |

## Workflow

```text
Source → Extract Audio (if needed) → Select Model → Transcribe → Output
```

1. **Detect source**: YouTube URL, media URL, local audio, or local video
2. **Extract audio**: `yt-dlp -x` (YouTube), `ffmpeg -vn` (video), direct (audio)
3. **Select model**: Local (faster-whisper/whisper.cpp) or cloud API (Groq/OpenAI/etc)
4. **Transcribe**: Run model, generate output in requested format
5. **Output**: Plain text, SRT, VTT, or JSON with timestamps

## Dependencies

```bash
brew install yt-dlp ffmpeg     # macOS (apt install on Linux)
pip install faster-whisper      # Local inference (recommended)
```

## Related

- `tools/voice/buzz.md` - Buzz GUI/CLI for offline Whisper transcription
- `tools/voice/speech-to-speech.md` - Full voice pipeline (VAD + STT + LLM + TTS)
- `tools/voice/voice-models.md` - TTS models for speech generation
- `voice-helper.sh` - CLI for voice operations
