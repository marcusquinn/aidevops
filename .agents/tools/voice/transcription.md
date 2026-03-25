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

```bash
transcription-helper.sh transcribe "https://youtu.be/dQw4w9WgXcQ"  # YouTube
transcription-helper.sh transcribe recording.mp3                    # Local file
transcription-helper.sh transcribe recording.mp3 --model large-v3-turbo
transcription-helper.sh models
```

<!-- AI-CONTEXT-END -->

## Decision Matrix

| Criterion | Whisper (local) | Buzz (GUI) | AssemblyAI | Deepgram |
|-----------|----------------|------------|------------|----------|
| **Privacy** | Full (offline) | Full (offline) | Cloud | Cloud |
| **Cost** | Free | Free | $0.15/hr (U2) – $0.45/hr (U3 Pro) | $0.0077/min (Nova-3) |
| **Setup** | pip + ffmpeg | brew install | API key only | API key only |
| **Accuracy** | 9.0–9.8 | 9.0–9.8 | 9.6 (U2) | 9.5 (Nova-3) |
| **Speaker diarization** | No | No | Yes | Yes |
| **Real-time streaming** | No | No | Yes (WebSocket) | Yes (WebSocket) |
| **Best for** | Private/offline, long files | macOS GUI users | Speaker ID, meetings | Real-time, low latency |

**Decision flow**:

1. Privacy required or no internet → Whisper or Buzz
2. Need speaker diarization → AssemblyAI or Deepgram
3. Real-time streaming → Deepgram
4. Highest accuracy, cloud OK → AssemblyAI Universal-3 Pro
5. Free, good enough → Whisper turbo locally

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

Runs locally via Python. `faster-whisper` is faster for the same models.

```bash
pip install openai-whisper
brew install ffmpeg

whisper audio.mp3                                          # Basic (auto-detects language)
whisper audio.mp3 --model medium --language en
whisper audio.mp3 --model medium --output_format srt      # SRT subtitles
whisper video.mp4 --model large --language en --output_format txt
whisper french-audio.mp3 --task translate --model medium  # Translate to English
whisper audio.mp3 --model medium --output_format json     # Word-level timestamps
```

### Model Selection

| Model | Size | Speed | Accuracy | Use case |
|-------|------|-------|----------|----------|
| `tiny` | 75MB | Fastest | 6.0/10 | Draft/preview only |
| `base` | 142MB | Fast | 7.3/10 | Quick transcription |
| `small` | 461MB | Medium | 8.5/10 | Good balance, multilingual |
| `medium` | 1.5GB | Slow | 9.0/10 | Solid quality, recommended default |
| `large-v3` | 2.9GB | Slowest | 9.8/10 | Best quality, best multilingual |
| **`turbo`** | **1.5GB** | **Fast** | **9.7/10** | **Large-v3 quality at medium speed** |
| NVIDIA Parakeet V2 | 474MB | Fastest | 9.4/10 | English-only |
| Apple Speech | Built-in | Fast | 9.0/10 | macOS 26+, on-device |

**Recommendation**: `medium` for most use cases; `turbo` when speed matters; `large-v3` for accuracy-critical work.

### faster-whisper (Recommended for Performance)

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

### whisper.cpp (C++ Native, Apple Silicon Optimised)

```bash
git clone https://github.com/ggml-org/whisper.cpp
cd whisper.cpp && make
./models/download-ggml-model.sh medium
./build/bin/whisper-cli -m models/ggml-medium.bin -f audio.wav -otxt -osrt
```

---

## Buzz (macOS GUI for Whisper)

Desktop app wrapping Whisper models. No cloud, no API key.

```bash
brew install --cask buzz    # macOS GUI (recommended)
pip install buzz-captions   # CLI / Python
# Or: https://buzzcaptions.com
```

**GUI**: File → Open → choose model (medium recommended) → Transcribe → Export (TXT/SRT/VTT).

```bash
buzz transcribe audio.mp3 --model medium --output-format srt
buzz transcribe foreign.mp3 --task translate --language auto
buzz transcribe audio.mp3 --model-type faster-whisper --model large-v3
```

**Supported formats**: Audio (MP3, WAV, FLAC, OGG, M4A, WMA), Video (MP4, MKV, AVI, MOV, WebM), Output (TXT, SRT, VTT, JSON).

---

## AssemblyAI (Cloud — Speaker Diarization, High Accuracy)

Best for meeting transcription where you need to identify who said what.

```bash
pip install assemblyai
# Store API key: aidevops secret set ASSEMBLYAI_API_KEY
```

```python
import assemblyai as aai, os
aai.settings.api_key = os.environ["ASSEMBLYAI_API_KEY"]
transcriber = aai.Transcriber()

# Basic
transcript = transcriber.transcribe("audio.mp3")
print(transcript.text)

# Speaker diarization
config = aai.TranscriptionConfig(speaker_labels=True, speakers_expected=3)
transcript = transcriber.transcribe("meeting.mp3", config=config)
for utterance in transcript.utterances:
    print(f"Speaker {utterance.speaker}: {utterance.text}")

# Advanced features
config = aai.TranscriptionConfig(
    speaker_labels=True, auto_chapters=True, sentiment_analysis=True,
    entity_detection=True, auto_highlights=True, language_detection=True,
    punctuate=True, format_text=True
)

# Webhook (production)
config = aai.TranscriptionConfig(webhook_url="https://yourapp.com/webhook")
transcript = transcriber.submit("audio.mp3", config=config)
print(transcript.id)  # poll later
```

### Pricing

| Model | Batch | Streaming | Notes |
|-------|-------|-----------|-------|
| Universal-3 Pro | $0.21/hr | $0.45/hr | Promptable, 6 languages |
| Universal-2 | $0.15/hr | — | 99 languages, general-purpose |
| Universal-Streaming | — | $0.15/hr | English-only, fastest |
| Universal-Streaming Multilingual | — | $0.15/hr | 6 languages |
| Whisper-Streaming | — | $0.30/hr | 99+ languages |

> Last verified: March 2026 — [assemblyai.com/pricing](https://www.assemblyai.com/pricing)

---

## Deepgram (Cloud — Real-Time, Low Latency)

Best for live transcription, call centres, and latency-sensitive applications.

```bash
pip install deepgram-sdk
# Store API key: aidevops secret set DEEPGRAM_API_KEY
```

```python
from deepgram import DeepgramClient, PrerecordedOptions
import os

deepgram = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])

# Batch from file
with open("audio.mp3", "rb") as f:
    options = PrerecordedOptions(model="nova-3", language="en", punctuate=True, diarize=True, smart_format=True)
    response = deepgram.listen.rest.v("1").transcribe_file({"buffer": f}, options)
    print(response.results.channels[0].alternatives[0].transcript)

# Batch from URL
response = deepgram.listen.rest.v("1").transcribe_url({"url": "https://example.com/audio.mp3"}, PrerecordedOptions(model="nova-3", diarize=True))

# Speaker diarization
words = response.results.channels[0].alternatives[0].words
for word in words:
    print(f"[Speaker {word.speaker}] {word.word}")
```

### Real-Time Streaming

```python
from deepgram import DeepgramClient, LiveTranscriptionEvents, LiveOptions
import asyncio, os

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

### Models & Pricing

| Model | Accuracy | Cost | Notes |
|-------|----------|------|-------|
| `nova-3` | 9.5/10 | $0.0077/min | General purpose, 36 languages |
| `nova-3-medical` | 9.6/10 | $0.0077/min | Clinical vocabulary, English only |
| `nova-3` (Multilingual) | 9.5/10 | $0.0092/min | 45+ languages |
| `nova-2` | 9.3/10 | $0.0058/min | Previous gen, wider language support |

> Last verified: March 2026 — [deepgram.com/pricing](https://deepgram.com/pricing)

---

## Cloud APIs (Extended)

| Provider | Model | Accuracy | Cost | Notes |
|----------|-------|----------|------|-------|
| **Groq** | Whisper Large v3 Turbo | 9.6/10 | Free tier | OpenAI-compatible API |
| **ElevenLabs** | Scribe v2 | 9.9/10 | Pay/min | Highest accuracy |
| **Mistral** | Voxtral Mini | 9.7/10 | Pay/token | Multilingual |
| **OpenAI** | Whisper API | 9.5/10 | $0.006/min | Reference implementation |
| **Google** | Gemini 2.5 Pro | 9.7/10 | Pay/token | Multimodal input |
| **Soniox** | stt-async-v3 | 9.6/10 | Batch | Batch processing |

Store API keys: `aidevops secret set <PROVIDER>_API_KEY`

```bash
# Groq (OpenAI-compatible)
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
# AssemblyAI (with speaker diarization)
python3 - <<'EOF'
import assemblyai as aai, os
aai.settings.api_key = os.environ["ASSEMBLYAI_API_KEY"]
config = aai.TranscriptionConfig(speaker_labels=True, auto_chapters=True)
t = aai.Transcriber().transcribe("meeting.mp4", config=config)
for u in t.utterances:
    print(f"[Speaker {u.speaker}] {u.text}")
EOF

# Local Whisper (no speaker labels, but private)
whisper meeting.mp4 --model medium --language en --output_format txt
```

### Video Subtitles (SRT/VTT)

```bash
# Local Whisper
whisper video.mp4 --model medium --output_format srt

# AssemblyAI (cloud, higher accuracy)
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
whisper episode.mp3 --model turbo --language en --output_format txt
cat episode.txt | claude "Summarise this podcast transcript into:
1. Key topics (bullet points)
2. Notable quotes (3-5)
3. Action items mentioned
4. Guest names and affiliations"
```

### Batch Transcription

```bash
# Local Whisper
for f in recordings/*.mp3; do
  whisper "$f" --model medium --output_format txt --output_dir transcripts/
done

# Deepgram (parallel, faster)
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
yt-dlp -x --audio-format mp3 -o "youtube_video.%(ext)s" "https://youtu.be/VIDEO_ID"
whisper "youtube_video.mp3" --model medium --language en --output_format txt
# Or use the helper (handles download + transcription):
transcription-helper.sh transcribe "https://youtu.be/VIDEO_ID"
```

---

## Language Support

Whisper auto-detects language by default (omit `--language`). Specify for accuracy:

```bash
whisper audio.mp3 --language fr   # French
whisper audio.mp3 --language zh   # Chinese (Mandarin)
whisper audio.mp3 --language es   # Spanish
```

Whisper supports 99 languages. Full list: https://github.com/openai/whisper#available-models-and-languages

AssemblyAI: 99 languages — `aai.TranscriptionConfig(language_code="fr")` or `language_detection=True`

Deepgram Nova-3: 36 languages — `PrerecordedOptions(model="nova-3", language="fr")`. Use `nova-2` for broader coverage (100+ languages).

---

## Output Formats

| Format | Use Case | Tool support |
|--------|----------|-------------|
| `.txt` | Reading, search indexing, LLM input | All tools |
| `.srt` | Video subtitles (most compatible) | Whisper, Buzz, AssemblyAI |
| `.vtt` | Web video subtitles | Whisper, Buzz, AssemblyAI |
| `.json` | Programmatic access, word timestamps | All tools |

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
