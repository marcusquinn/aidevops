---
description: Audio/video transcription with local and cloud models — Whisper, Buzz, AssemblyAI, Deepgram
mode: subagent
tools:
  read: true
  bash: true
---

# Audio/Video Transcription

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Transcribe audio/video from local files, YouTube URLs, or cloud uploads
- **Helper**: `transcription-helper.sh [transcribe|models|configure|install|status] [options]`
- **Default local model**: Whisper Large v3 Turbo (best speed/accuracy tradeoff)
- **Dependencies**: `yt-dlp` (YouTube), `ffmpeg` (audio extraction), `faster-whisper` or `whisper.cpp` (local)

**Quick Commands**:

```bash
# Transcribe YouTube video (local Whisper)
transcription-helper.sh transcribe "https://youtu.be/dQw4w9WgXcQ"

# Transcribe local file
transcription-helper.sh transcribe recording.mp3

# Transcribe with specific model
transcription-helper.sh transcribe recording.mp3 --model large-v3-turbo

# List available models
transcription-helper.sh models
```

<!-- AI-CONTEXT-END -->

## Decision Matrix

Use this to pick the right tool before starting.

| Criterion | Whisper (local) | Buzz (GUI) | AssemblyAI | Deepgram |
|-----------|----------------|------------|------------|----------|
| **Privacy** | Full (no data leaves device) | Full (offline) | Cloud (data sent) | Cloud (data sent) |
| **Cost** | Free | Free | $0.12/hr (Nano) – $0.65/hr (Best) | $0.0043/min (Nova-3) |
| **Setup** | pip + ffmpeg | brew install | API key only | API key only |
| **Accuracy** | 9.0–9.8 (model-dependent) | 9.0–9.8 | 9.6 (Universal-2) | 9.5 (Nova-3) |
| **Speed** | Slow–medium (CPU/GPU) | Medium (GUI) | Fast (async) | Real-time capable |
| **Speaker diarization** | No (base Whisper) | No | Yes | Yes |
| **Timestamps** | Word-level (JSON) | Yes | Word-level | Word-level |
| **Batch/async** | Yes (CLI loop) | No | Yes (webhooks) | Yes |
| **Real-time streaming** | No | No | Yes (WebSocket) | Yes (WebSocket) |
| **Language detection** | Auto (99 languages) | Auto | Auto (99 languages) | Auto (36 languages) |
| **Best for** | Private/offline, long files | macOS GUI users | Speaker ID, meetings | Real-time, low latency |

**Decision flow**:

1. **Privacy required or no internet** → Whisper local or Buzz
2. **Need speaker diarization** → AssemblyAI or Deepgram
3. **Real-time streaming** → Deepgram
4. **Highest accuracy, cloud OK** → AssemblyAI Universal-2
5. **Free, good enough** → Whisper medium or large-v3-turbo locally

---

## Input Sources

| Source | Detection | Extraction |
|--------|-----------|------------|
| YouTube URL | `youtu.be/` or `youtube.com/watch` | `yt-dlp -x --audio-format wav` |
| Direct media URL | HTTP(S) with media extension | `curl` + `ffmpeg` if video |
| Local audio | `.wav`, `.mp3`, `.flac`, `.ogg`, `.m4a` | Direct input |
| Local video | `.mp4`, `.mkv`, `.webm`, `.avi` | `ffmpeg -i input -vn -acodec pcm_s16le` |

---

## Whisper (Local — OpenAI Original)

The original OpenAI Whisper model. Runs locally via Python. Good baseline; `faster-whisper` is faster for the same models.

### Installation

```bash
pip install openai-whisper
brew install ffmpeg   # required dependency
```

### CLI Usage

```bash
# Basic transcription (auto-detects language)
whisper audio.mp3

# Specify model and language
whisper audio.mp3 --model medium --language en

# Output as SRT subtitles
whisper audio.mp3 --model medium --output_format srt

# Transcribe video (extracts audio automatically)
whisper video.mp4 --model large --language en --output_format txt

# Translate non-English audio to English
whisper french-audio.mp3 --task translate --model medium

# Word-level timestamps (JSON output)
whisper audio.mp3 --model medium --output_format json
```

### Model Selection

| Model | Size | Speed | Accuracy | Use case |
|-------|------|-------|----------|----------|
| `tiny` | 75MB | Fastest | 6.0/10 | Draft/preview only |
| `base` | 142MB | Fast | 7.3/10 | Quick transcription |
| `small` | 461MB | Medium | 8.5/10 | Good balance, multilingual |
| `medium` | 1.5GB | Slow | 9.0/10 | Solid quality, recommended default |
| `large` | 2.9GB | Slowest | 9.8/10 | Best quality |
| `large-v3` | 2.9GB | Slowest | 9.8/10 | Latest, best multilingual |
| `turbo` | 1.5GB | Fast | 9.7/10 | Large-v3 quality at medium speed |

**Recommendation**: `medium` for most use cases; `turbo` when speed matters; `large-v3` for accuracy-critical work.

### via faster-whisper (Recommended for Performance)

CTranslate2-based, 4x faster than original Whisper with identical accuracy.

```bash
pip install faster-whisper
```

```python
from faster_whisper import WhisperModel

model = WhisperModel("medium", device="cpu", compute_type="int8")
segments, info = model.transcribe("audio.mp3", language="en")
for segment in segments:
    print(f"[{segment.start:.2f}s] {segment.text}")
```

### via whisper.cpp (C++ Native, Apple Silicon Optimised)

```bash
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp && make
./models/download-ggml-model.sh medium
./build/bin/whisper-cli -m models/ggml-medium.bin -f audio.wav -otxt -osrt
```

---

## Buzz (macOS GUI for Whisper)

Desktop app wrapping Whisper models. No cloud, no API key. Best for users who prefer a GUI over CLI.

### Installation

```bash
# macOS GUI app (recommended)
brew install --cask buzz

# CLI / Python
pip install buzz-captions
```

Or download from https://buzzcaptions.com

### GUI Workflow

1. Open Buzz → File → Open
2. Select audio or video file
3. Choose model (medium recommended) and language
4. Click Transcribe
5. Export as TXT, SRT, or VTT

### CLI Usage

```bash
# Transcribe with timestamps
buzz transcribe audio.mp3 --model medium --output-format srt

# Translate to English
buzz transcribe foreign.mp3 --task translate --language auto

# Use faster-whisper backend (faster, lower memory)
buzz transcribe audio.mp3 --model-type faster-whisper --model large-v3
```

### Supported Formats

- **Audio**: MP3, WAV, FLAC, OGG, M4A, WMA
- **Video**: MP4, MKV, AVI, MOV, WebM (extracts audio automatically)
- **Output**: TXT, SRT, VTT, JSON

---

## AssemblyAI (Cloud — Speaker Diarization, High Accuracy)

Cloud API with speaker diarization, sentiment analysis, and auto-chapters. Best for meeting transcription where you need to identify who said what.

### Installation

```bash
pip install assemblyai
```

Store API key: `aidevops secret set ASSEMBLYAI_API_KEY`

### Basic Transcription

```python
import assemblyai as aai
import os

aai.settings.api_key = os.environ["ASSEMBLYAI_API_KEY"]
transcriber = aai.Transcriber()

# From local file
transcript = transcriber.transcribe("audio.mp3")
print(transcript.text)

# From URL
transcript = transcriber.transcribe("https://example.com/audio.mp3")
print(transcript.text)
```

### Speaker Diarization (Meeting Transcription)

```python
config = aai.TranscriptionConfig(
    speaker_labels=True,
    speakers_expected=3,   # optional hint
    language_code="en"
)
transcript = transcriber.transcribe("meeting.mp3", config=config)

for utterance in transcript.utterances:
    print(f"Speaker {utterance.speaker}: {utterance.text}")
```

### Advanced Features

```python
config = aai.TranscriptionConfig(
    speaker_labels=True,
    auto_chapters=True,        # topic segmentation
    sentiment_analysis=True,   # per-sentence sentiment
    entity_detection=True,     # names, places, orgs
    auto_highlights=True,      # key phrases
    language_detection=True,   # auto-detect language
    punctuate=True,
    format_text=True
)
```

### Async / Webhook

```python
# Submit and poll
transcript = transcriber.transcribe("long-audio.mp3")
# Blocks until complete; use submit() + poll() for non-blocking

# Webhook (production)
config = aai.TranscriptionConfig(webhook_url="https://yourapp.com/webhook")
transcript = transcriber.submit("audio.mp3", config=config)
print(transcript.id)  # poll later
```

### Pricing (2025)

| Tier | Model | Cost |
|------|-------|------|
| Nano | Best/Nano | $0.12/hr |
| Default | Universal-2 | $0.37/hr |
| Best | Universal-2 + features | $0.65/hr |

---

## Deepgram (Cloud — Real-Time, Low Latency)

Cloud API optimised for real-time streaming and batch. Best for live transcription, call centres, and latency-sensitive applications.

### Installation

```bash
pip install deepgram-sdk
```

Store API key: `aidevops secret set DEEPGRAM_API_KEY`

### Batch Transcription

```python
from deepgram import DeepgramClient, PrerecordedOptions
import os

deepgram = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])

# From local file
with open("audio.mp3", "rb") as f:
    payload = {"buffer": f}
    options = PrerecordedOptions(
        model="nova-3",
        language="en",
        punctuate=True,
        diarize=True,
        smart_format=True
    )
    response = deepgram.listen.rest.v("1").transcribe_file(payload, options)
    print(response.results.channels[0].alternatives[0].transcript)

# From URL
options = PrerecordedOptions(model="nova-3", diarize=True)
response = deepgram.listen.rest.v("1").transcribe_url(
    {"url": "https://example.com/audio.mp3"}, options
)
```

### Real-Time Streaming

```python
from deepgram import DeepgramClient, LiveTranscriptionEvents, LiveOptions
import asyncio

async def stream_microphone():
    dg = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])
    connection = dg.listen.asyncwebsocket.v("1")

    async def on_message(result, **kwargs):
        sentence = result.channel.alternatives[0].transcript
        if sentence:
            print(sentence)

    connection.on(LiveTranscriptionEvents.Transcript, on_message)
    options = LiveOptions(model="nova-3", language="en-US", smart_format=True)
    await connection.start(options)
    # feed audio chunks via connection.send(audio_chunk)
```

### Speaker Diarization

```python
options = PrerecordedOptions(
    model="nova-3",
    diarize=True,
    punctuate=True
)
response = deepgram.listen.rest.v("1").transcribe_url({"url": "https://example.com/audio.mp3"}, options)
words = response.results.channels[0].alternatives[0].words
for word in words:
    print(f"[Speaker {word.speaker}] {word.word}")
```

### Models

| Model | Accuracy | Speed | Notes |
|-------|----------|-------|-------|
| `nova-3` | 9.5/10 | Fast | General purpose, 36 languages |
| `nova-3-medical` | 9.6/10 | Fast | Clinical vocabulary, English only |
| `nova-2` | 9.3/10 | Fast | Previous gen, wider language support |
| `enhanced` | 9.0/10 | Medium | Legacy |
| `base` | 8.5/10 | Fastest | Lowest cost |

### Pricing (2025)

| Model | Cost |
|-------|------|
| Nova-3 | $0.0043/min |
| Nova-3 Medical | $0.0059/min |
| Nova-2 | $0.0043/min |

---

## Cloud APIs (Extended)

| Provider | Model | Accuracy | Speed | Cost | Notes |
|----------|-------|----------|-------|------|-------|
| **Groq** | Whisper Large v3 Turbo | 9.6/10 | Lightning | Free tier | OpenAI-compatible API |
| **ElevenLabs** | Scribe v2 | 9.9/10 | Fast | Pay/min | Highest accuracy |
| **Mistral** | Voxtral Mini | 9.7/10 | Fast | Pay/token | Multilingual |
| **OpenAI** | Whisper API | 9.5/10 | Fast | $0.006/min | Reference implementation |
| **Google** | Gemini 2.5 Pro | 9.7/10 | Fast | Pay/token | Multimodal input |
| **Soniox** | stt-async-v3 | 9.6/10 | Async | Batch | Batch processing |

Store API keys: `aidevops secret set <PROVIDER>_API_KEY`

Example (Groq — OpenAI-compatible):

```bash
curl https://api.groq.com/openai/v1/audio/transcriptions \
  -H "Authorization: Bearer ${GROQ_API_KEY}" \
  -F "file=@audio.wav" \
  -F "model=whisper-large-v3" \
  -F "response_format=verbose_json"
```

---

## Common Workflows

### Meeting Transcription with Speaker Labels

```bash
# 1. Record meeting (Zoom/Teams/Google Meet → export MP4)
# 2. Transcribe with speaker diarization (AssemblyAI)
python3 - <<'EOF'
import assemblyai as aai, os
aai.settings.api_key = os.environ["ASSEMBLYAI_API_KEY"]
config = aai.TranscriptionConfig(speaker_labels=True, auto_chapters=True)
t = aai.Transcriber().transcribe("meeting.mp4", config=config)
for u in t.utterances:
    print(f"[Speaker {u.speaker}] {u.text}")
EOF

# 3. Or use local Whisper (no speaker labels, but private)
whisper meeting.mp4 --model medium --language en --output_format txt
```

### Video Subtitles (SRT/VTT)

```bash
# Local Whisper → SRT
whisper video.mp4 --model medium --output_format srt
# Output: video.srt (ready for YouTube, VLC, Premiere)

# Buzz GUI → SRT
buzz transcribe video.mp4 --model large-v3 --output-format srt

# AssemblyAI → SRT (cloud, higher accuracy)
python3 - <<'EOF'
import assemblyai as aai, os
aai.settings.api_key = os.environ["ASSEMBLYAI_API_KEY"]
t = aai.Transcriber().transcribe("video.mp4")
with open("subtitles.srt", "w") as f:
    f.write(t.export_subtitles_srt())
EOF
```

### Podcast Notes / Show Notes

```bash
# Transcribe episode
whisper episode.mp3 --model turbo --language en --output_format txt

# Then pipe to LLM for summary (example with Claude CLI)
cat episode.txt | claude "Summarise this podcast transcript into: 
1. Key topics (bullet points)
2. Notable quotes (3-5)
3. Action items mentioned
4. Guest names and affiliations"
```

### Batch Transcription

```bash
# Batch with local Whisper
for f in recordings/*.mp3; do
  whisper "$f" --model medium --output_format txt --output_dir transcripts/
done

# Batch with Deepgram (parallel, faster)
python3 - <<'EOF'
import os, glob
from deepgram import DeepgramClient, PrerecordedOptions

dg = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])
options = PrerecordedOptions(model="nova-3", punctuate=True, smart_format=True)
os.makedirs("transcripts", exist_ok=True)

for path in glob.glob("recordings/*.mp3"):
    with open(path, "rb") as f:
        resp = dg.listen.rest.v("1").transcribe_file({"buffer": f}, options)
        out = path.replace(".mp3", ".txt").replace("recordings/", "transcripts/")
        with open(out, "w") as o:
            o.write(resp.results.channels[0].alternatives[0].transcript)
    print(f"Done: {path}")
EOF
```

### YouTube Video Transcription

```bash
# Download audio then transcribe
yt-dlp -x --audio-format mp3 -o "youtube_video.%(ext)s" "https://youtu.be/VIDEO_ID"
whisper "youtube_video.mp3" --model medium --language en --output_format txt

# Or use the helper (handles download + transcription)
transcription-helper.sh transcribe "https://youtu.be/VIDEO_ID"
```

---

## Language Support

### Whisper (OpenAI) — 99 Languages

Auto-detects language by default (`--language auto`). Specify for accuracy:

```bash
whisper audio.mp3 --language fr   # French
whisper audio.mp3 --language zh   # Chinese (Mandarin)
whisper audio.mp3 --language es   # Spanish
```

| Language | Code | Notes |
|----------|------|-------|
| English | `en` | Best accuracy |
| Spanish | `es` | Strong support |
| French | `fr` | Strong support |
| German | `de` | Strong support |
| Chinese | `zh` | Mandarin, good |
| Japanese | `ja` | Good |
| Portuguese | `pt` | Good |
| Russian | `ru` | Good |
| Arabic | `ar` | Moderate |
| Hindi | `hi` | Moderate |
| Korean | `ko` | Good |
| Italian | `it` | Good |
| Dutch | `nl` | Good |
| Polish | `pl` | Good |
| Turkish | `tr` | Good |

Full list: https://github.com/openai/whisper#available-models-and-languages

### AssemblyAI — 99 Languages

```python
config = aai.TranscriptionConfig(language_code="fr")  # or language_detection=True
```

### Deepgram — 36 Languages (Nova-3)

```python
options = PrerecordedOptions(model="nova-3", language="fr")
# Use nova-2 for broader language coverage (100+ languages)
```

---

## Output Formats

| Format | Use Case | Tool support |
|--------|----------|-------------|
| `.txt` | Reading, search indexing, LLM input | All tools |
| `.srt` | Video subtitles (most compatible) | Whisper, Buzz, AssemblyAI |
| `.vtt` | Web video subtitles | Whisper, Buzz, AssemblyAI |
| `.json` | Programmatic access, word timestamps | All tools |

---

## Local Model Comparison

| Model | Size | Speed | Accuracy | Best for |
|-------|------|-------|----------|----------|
| Tiny | 75MB | 9.5/10 | 6.0/10 | Draft/preview only |
| Base | 142MB | 8.5/10 | 7.3/10 | Quick transcription |
| Small | 461MB | 7.0/10 | 8.5/10 | Good balance, multilingual |
| Medium | 1.5GB | 5.0/10 | 9.0/10 | Solid quality |
| Large v3 | 2.9GB | 3.0/10 | 9.8/10 | Best quality |
| **Turbo** | **1.5GB** | **7.5/10** | **9.7/10** | **Recommended default** |
| NVIDIA Parakeet V2 | 474MB | 9.9/10 | 9.4/10 | English-only, fastest |
| Apple Speech | Built-in | 9.0/10 | 9.0/10 | macOS 26+, on-device |

---

## Dependencies

```bash
brew install yt-dlp ffmpeg          # macOS (apt install on Linux)
pip install openai-whisper          # Original Whisper CLI
pip install faster-whisper          # Faster local inference (recommended)
pip install assemblyai              # AssemblyAI cloud API
pip install deepgram-sdk            # Deepgram cloud API
brew install --cask buzz            # Buzz macOS GUI
```

---

## Related

- `tools/voice/buzz.md` — Buzz GUI/CLI for offline Whisper transcription
- `tools/voice/speech-to-speech.md` — Full voice pipeline (VAD + STT + LLM + TTS)
- `tools/voice/voice-models.md` — TTS models for speech generation
- `tools/video/yt-dlp.md` — YouTube download helper
- `transcription-helper.sh` — CLI wrapper for all transcription workflows
