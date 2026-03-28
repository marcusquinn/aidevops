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

- **Helper**: `transcription-helper.sh [transcribe|models|configure|install|status] [options]`
- **Default**: Whisper Large v3 Turbo (best speed/accuracy tradeoff)
- **Deps**: `yt-dlp` (YouTube), `ffmpeg` (audio extraction), `faster-whisper` or `whisper.cpp` (local)

```bash
transcription-helper.sh transcribe "https://youtu.be/VIDEO_ID"  # YouTube
transcription-helper.sh transcribe recording.mp3 --model large-v3-turbo  # helper model name; native whisper uses --model turbo
brew install yt-dlp ffmpeg && brew install --cask buzz           # macOS deps
pip install openai-whisper faster-whisper assemblyai deepgram-sdk
```

<!-- AI-CONTEXT-END -->

## Decision Matrix

| Criterion | Whisper (local) | Buzz (GUI) | AssemblyAI | Deepgram |
|-----------|----------------|------------|------------|----------|
| **Privacy** | Full (offline) | Full (offline) | Cloud | Cloud |
| **Cost** | Free | Free | $0.15-$0.45/hr | $0.0077/min |
| **Setup** | pip + ffmpeg | brew install | API key | API key |
| **Accuracy** | 9.0-9.8 | 9.0-9.8 | 9.6 | 9.5 |
| **Diarization** | No | No | Yes | Yes |
| **Streaming** | No | No | Yes | Yes |
| **Best for** | Private/offline | macOS GUI | Speaker ID, meetings | Real-time |

**Decision flow**: Privacy/offline → Whisper/Buzz. Speaker diarization → AssemblyAI/Deepgram. Real-time → Deepgram. Highest accuracy → ElevenLabs Scribe v2 (9.9/10); best full-featured cloud → AssemblyAI U3 Pro (diarization + chapters). Free → Whisper turbo.

**Input sources**: YouTube (`yt-dlp -x --audio-format wav`), URL (`curl` + `ffmpeg`), local audio (`.wav .mp3 .flac .ogg .m4a`), local video (`ffmpeg -i input -vn -acodec pcm_s16le output.wav`).

## Whisper (Local)

`faster-whisper` (CTranslate2) is 2-4x faster with comparable accuracy.

```bash
whisper audio.mp3 --model medium --language en                   # basic
whisper audio.mp3 --model medium --output_format srt             # subtitles
whisper audio.mp3 --model medium --output_format json            # word timestamps
whisper foreign.mp3 --task translate --model medium              # translate to English
for f in recordings/*.mp3; do whisper "$f" --model medium --output_format txt --output_dir transcripts/; done
```

### Models

| Model | Size | Speed | Accuracy | Use case |
|-------|------|-------|----------|----------|
| `tiny`/`base` | 75-142MB | Fastest | 6-7/10 | Draft/preview |
| `small` | 461MB | Medium | 8.5/10 | Good balance, multilingual |
| `medium` | 1.5GB | Slow | 9.0/10 | **Recommended default** |
| `large-v3` | 2.9GB | Slowest | 9.8/10 | Best quality/multilingual |
| **`turbo`** | **1.5GB** | **Fast** | **9.7/10** | **Large-v3 quality, medium speed** |
| Parakeet V2 | 474MB | Fastest | 9.4/10 | English-only (NVIDIA) |
| Apple Speech | Built-in | Fast | 9.0/10 | macOS 26+, on-device |

### faster-whisper / whisper.cpp

```python
from faster_whisper import WhisperModel  # pip install faster-whisper
model = WhisperModel("medium", device="cpu", compute_type="int8")
for seg, _ in model.transcribe("audio.mp3", language="en"):
    print(f"[{seg.start:.2f}s] {seg.text}")
```

```bash
# whisper.cpp — Apple Silicon optimised
git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp && make
./models/download-ggml-model.sh medium
./build/bin/whisper-cli -m models/ggml-medium.bin -f audio.wav -otxt -osrt
```

## Buzz (macOS GUI for Whisper)

Desktop Whisper wrapper. No cloud/API key. Audio: MP3/WAV/FLAC/OGG/M4A/WMA. Video: MP4/MKV/AVI/MOV/WebM. Output: TXT/SRT/VTT/JSON.

```bash
brew install --cask buzz                                         # GUI: File → Open → Transcribe → Export
pip install buzz-captions                                        # CLI package
buzz transcribe audio.mp3 --model medium --output-format srt     # CLI
buzz transcribe foreign.mp3 --task translate --language auto
buzz transcribe audio.mp3 --model-type faster-whisper --model large-v3
```

## AssemblyAI (Cloud — Speaker Diarization)

Best for meetings with speaker identification. `aidevops secret set ASSEMBLYAI_API_KEY`

```python
import assemblyai as aai, os
aai.settings.api_key = os.environ["ASSEMBLYAI_API_KEY"]
config = aai.TranscriptionConfig(speaker_labels=True, speakers_expected=3, auto_chapters=True)
transcript = aai.Transcriber().transcribe("meeting.mp3", config=config)
for u in transcript.utterances: print(f"Speaker {u.speaker}: {u.text}")
# Subtitles: transcript.export_subtitles_srt()
# Async: aai.Transcriber().submit("audio.mp3", aai.TranscriptionConfig(webhook_url="https://..."))
```

Config options: `sentiment_analysis`, `entity_detection`, `auto_highlights`, `language_detection`, `punctuate`, `format_text`.

| Model | Batch | Streaming | Notes |
|-------|-------|-----------|-------|
| Universal-3 Pro | $0.21/hr | $0.45/hr | Promptable, 6 languages |
| Universal-2 | $0.15/hr | — | 99 languages |
| Universal-Streaming | — | $0.15/hr | English-only / 6-lang multilingual |
| Whisper-Streaming | — | $0.30/hr | 99+ languages |

> Last verified: March 2026 — [assemblyai.com/pricing](https://www.assemblyai.com/pricing)

## Deepgram (Cloud — Real-Time, Low Latency)

Best for live transcription and latency-sensitive apps. `aidevops secret set DEEPGRAM_API_KEY`

```python
from deepgram import DeepgramClient, PrerecordedOptions
import os
dg = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])
opts = PrerecordedOptions(model="nova-3", language="en", punctuate=True, diarize=True, smart_format=True)
with open("audio.mp3", "rb") as f:
    resp = dg.listen.rest.v("1").transcribe_file({"buffer": f}, opts)
alt = resp.results.channels[0].alternatives[0]
print(alt.transcript)
for word in alt.words: print(f"[Speaker {word.speaker}] {word.word}")
```

### Streaming

```python
from deepgram import DeepgramClient, LiveTranscriptionEvents, LiveOptions
import os
dg = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])
conn = dg.listen.asyncwebsocket.v("1")
conn.on(LiveTranscriptionEvents.Transcript, lambda r, **kw: print(r.channel.alternatives[0].transcript) or None)
await conn.start(LiveOptions(model="nova-3", language="en-US", smart_format=True))
# feed audio chunks via conn.send(audio_chunk)
```

<details>
<summary>Batch processing example</summary>

```python
import os, glob
from deepgram import DeepgramClient, PrerecordedOptions
dg = DeepgramClient(os.environ["DEEPGRAM_API_KEY"])
opts = PrerecordedOptions(model="nova-3", punctuate=True, smart_format=True)
os.makedirs("transcripts", exist_ok=True)
for p in glob.glob("recordings/*.mp3"):
    with open(p, "rb") as audio:
        r = dg.listen.rest.v("1").transcribe_file({"buffer": audio}, opts)
    out = os.path.join("transcripts", os.path.basename(p).replace(".mp3", ".txt"))
    with open(out, "w") as f:
        f.write(r.results.channels[0].alternatives[0].transcript)
```

</details>

| Model | Accuracy | Cost | Notes |
|-------|----------|------|-------|
| `nova-3` | 9.5/10 | $0.0077/min | General purpose, 36 languages |
| `nova-3-medical` | 9.6/10 | $0.0077/min | Clinical vocabulary, English only |
| `nova-3` Multilingual | 9.5/10 | $0.0092/min | 45+ languages |
| `nova-2` | 9.3/10 | $0.0058/min | Previous gen, wider language support |

> Last verified: March 2026 — [deepgram.com/pricing](https://deepgram.com/pricing)

## Cloud APIs (Extended)

| Provider | Model | Accuracy | Cost | Notes |
|----------|-------|----------|------|-------|
| **Groq** | Whisper Large v3 Turbo | 9.6/10 | Free tier | OpenAI-compatible |
| **ElevenLabs** | Scribe v2 | 9.9/10 | Pay/min | Highest accuracy |
| **Mistral** | Voxtral Mini | 9.7/10 | Pay/token | Multilingual |
| **OpenAI** | Whisper API | 9.5/10 | $0.006/min | Reference impl |
| **Google** | Gemini 2.5 Pro | 9.7/10 | Pay/token | Multimodal input |
| **Soniox** | stt-async-v3 | 9.6/10 | Batch | Batch processing |

Store keys: `aidevops secret set <PROVIDER>_API_KEY`

```bash
curl https://api.groq.com/openai/v1/audio/transcriptions \
  -H "Authorization: Bearer ${GROQ_API_KEY}" \
  -F "file=@audio.wav" -F "model=whisper-large-v3" -F "response_format=verbose_json"
```

## Language & Output

**Languages** — Whisper: 99 (`--language fr/zh/es`). AssemblyAI: 99 (`language_code="fr"` or `language_detection=True`). Deepgram Nova-3: 36; `nova-2` for 100+. **Formats**: `.txt` (all), `.srt`/`.vtt` (Whisper, Buzz, AssemblyAI), `.json` word timestamps (all).

---

## Related

- `./buzz.md` — Buzz GUI/CLI for offline Whisper transcription
- `./speech-to-speech.md` — Full voice pipeline (VAD + STT + LLM + TTS)
- `./voice-models.md` — TTS models for speech generation
- `../video/yt-dlp.md` — YouTube download helper
- `../../scripts/transcription-helper.sh` — CLI wrapper for all transcription workflows
