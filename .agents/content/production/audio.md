---
name: audio
description: Audio production pipeline - voice, sound design, emotional cues, mixing
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

# Audio Production

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Professional audio production for content creation
- **Pipeline**: Voice cleanup → Voice transformation → Sound design → Mixing
- **Key Rule**: ALWAYS clean AI voice output with CapCut BEFORE ElevenLabs transformation
- **Helper**: `voice-helper.sh [talk|devices|voices|benchmark]`
- **References**: `tools/voice/speech-to-speech.md`, `voice-helper.sh`

**When to Use**: Read this when producing voiceovers, narration, podcasts, video audio, or any content requiring professional audio quality.

<!-- AI-CONTEXT-END -->

## Voice Production Pipeline

### Critical 2-Step Voice Workflow

**NEVER go directly from AI video output to ElevenLabs.** Always use this sequence:

```text
AI Video Output → CapCut AI Voice Cleanup → ElevenLabs Transformation → Final Audio
```

**Why this matters:**

1. **CapCut AI Voice Cleanup** (FIRST):
   - Normalizes accents and artifacts from raw AI output
   - Removes robotic patterns and unnatural cadence
   - Cleans background noise and audio artifacts
   - Standardizes volume and tone

2. **ElevenLabs Transformation** (SECOND):
   - Voice cloning for consistent channel narration
   - Emotional delivery and natural speech patterns
   - Character voice consistency across videos
   - Professional voice quality

**Common mistake**: Feeding raw AI video audio directly to ElevenLabs produces poor results because the artifacts and unnatural patterns get amplified during transformation.

### Voice Cloning Workflow

For consistent channel narration across multiple videos:

```bash
# 1. Record or extract clean voice sample (3-5 minutes minimum)
# 2. Upload to ElevenLabs voice library
# 3. Use cloned voice for all channel content

# Voice bridge for interactive voice (development/testing)
voice-helper.sh talk              # Start voice conversation
voice-helper.sh voices            # List available TTS voices
```

**Voice consistency checklist:**

- [ ] Same voice model across all channel content
- [ ] Consistent speaking pace (words per minute)
- [ ] Matching emotional tone for content type
- [ ] Standardized pronunciation for brand terms
- [ ] Voice sample updated quarterly for quality

### Emotional Block Cues

Per-word emotion tagging for natural AI speech delivery. This technique dramatically improves the naturalness of AI-generated speech by giving the TTS model explicit emotional context.

**Format:**

```text
[neutral]Welcome to the channel.[/neutral] [excited]Today we're covering something amazing![/excited] [serious]But first, let's understand the problem.[/serious]
```

**Available emotion tags:**

| Tag | Use Case | Example |
|-----|----------|---------|
| `[neutral]` | Default, informational | "Here's how it works." |
| `[excited]` | Hooks, reveals, wins | "This changed everything!" |
| `[serious]` | Problems, warnings, data | "95% of creators fail here." |
| `[curious]` | Questions, exploration | "What if we tried this?" |
| `[confident]` | Authority, expertise | "I've tested this 100 times." |
| `[empathetic]` | Pain points, struggles | "I know how frustrating this is." |
| `[urgent]` | CTAs, time-sensitive | "Don't miss this opportunity." |

**Emotional pacing rules:**

1. **Hook (0-3s)**: Start with `[excited]` or `[curious]` to grab attention
2. **Problem (3-10s)**: Shift to `[serious]` or `[empathetic]` to establish pain
3. **Solution (10s+)**: Use `[confident]` to deliver value
4. **CTA (final 5s)**: End with `[urgent]` or `[excited]` for action

**Example script with emotional blocks:**

```text
[excited]What if I told you there's a way to 10x your content output?[/excited]
[serious]Most creators spend 40 hours per video.[/serious]
[empathetic]I was stuck in that cycle for months.[/empathetic]
[confident]Then I discovered this AI pipeline.[/confident]
[excited]Now I produce 10 videos in the same time.[/excited]
[urgent]Let me show you exactly how.[/urgent]
```

**Integration with script writing:**

- Scripts from `content/production/writing.md` should include emotional block markup
- Voice actors (human or AI) use these as delivery cues
- TTS engines with emotion support (ElevenLabs, ChatTTS) parse these directly

## 4-Layer Audio Design

Professional audio is built in layers, not as a single track. This approach gives you mixing flexibility and professional polish.

### Layer 1: Dialogue (Primary)

**Target LUFS**: -15 (dialogue clarity)

- Voice narration or on-camera speech
- Highest priority in the mix
- Always centered (mono or center channel)
- EQ: High-pass filter at 80Hz, presence boost at 3-5kHz

**Processing chain:**

```text
Raw Voice → Noise Reduction → EQ → Compression → De-esser → Limiter → -15 LUFS
```

**Tools:**

- CapCut: AI voice cleanup, noise reduction
- ElevenLabs: Voice transformation, cloning
- Audacity/Audition: Manual cleanup, EQ, compression
- `voice-helper.sh`: Local voice processing

### Layer 2: Ambient Noise (Background)

**Target LUFS**: -25 (subtle presence)

- Environmental sound (office, street, nature)
- Establishes scene context
- Stereo width for immersion
- Low-pass filter to avoid competing with dialogue

**Content type ambient rules:**

| Content Type | Ambient Style | Example |
|--------------|---------------|---------|
| UGC/Vlog | Diegetic only | Room tone, keyboard clicks |
| Tutorial | Minimal/none | Silence or soft room tone |
| Documentary | Rich environmental | Location-specific ambience |
| Commercial | Designed ambience | Branded sonic environment |

**Where to source:**

- Freesound.org (CC0 and CC-BY)
- Epidemic Sound (subscription)
- Record custom ambience on location
- AI-generated ambience (AudioCraft, Stable Audio)

### Layer 3: SFX (Sound Effects)

**Target LUFS**: Varies by effect (-10 to -20)

- Punctuation for visual events
- Transitions between scenes
- UI sounds for motion graphics
- Impact sounds for reveals

**SFX categories:**

1. **Whooshes/Swooshes**: Scene transitions, motion graphics
2. **Impacts**: Reveals, text appearance, logo hits
3. **UI Sounds**: Button clicks, notifications, tech interfaces
4. **Foley**: Footsteps, object handling, physical actions
5. **Risers/Drops**: Build tension, release energy

**Timing rules:**

- SFX should land 1-2 frames BEFORE the visual event (anticipation)
- Layer multiple SFX for bigger impacts (e.g., whoosh + impact + reverb tail)
- Use reverb to place SFX in the same "space" as dialogue

### Layer 4: Music (Score)

**Target LUFS**: -18 to -20 (supporting role)

- Emotional tone and pacing
- Fills silence without competing with dialogue
- Ducking (auto-volume reduction) when dialogue plays

**Music selection by content type:**

| Content Type | Music Style | Ducking |
|--------------|-------------|---------|
| UGC | All diegetic (no score) | N/A |
| Tutorial | Minimal, ambient | -6dB during speech |
| Commercial | Mixed diegetic + score | -8dB during speech |
| Documentary | Cinematic score | -4dB during speech |
| YouTube | Upbeat, royalty-free | -6dB during speech |

**Music sources:**

- Epidemic Sound (subscription, YouTube-safe)
- Artlist (subscription, unlimited license)
- Uppbeat (free tier, attribution)
- AudioJungle (pay-per-track)
- AI-generated (Suno, Udio, Stable Audio) - check platform policies

**Ducking automation:**

Most NLEs (Premiere, DaVinci, Final Cut) support sidechain compression for automatic ducking. Set dialogue track as sidechain input, music track as target, threshold -20dB, ratio 4:1, attack 10ms, release 200ms.

## Platform Audio Rules

Different platforms and content types have different audio expectations. Violating these conventions makes content feel "off" even if technically correct.

### UGC (User-Generated Content)

**Rule**: All diegetic audio (sounds that exist in the scene)

- No background music unless it's playing in the scene
- Natural room tone and ambient noise
- Authentic, unpolished feel
- Dialogue can be slightly rough (adds authenticity)

**Why**: UGC audiences expect raw, authentic audio. Overly polished audio signals "produced content" and breaks trust.

**Examples**: TikTok vlogs, Instagram Stories, YouTube Shorts (personal)

### Commercial/Branded

**Rule**: Mixed diegetic + score

- Professional voice (ElevenLabs or pro voice actor)
- Designed ambience (not raw location audio)
- Music score for emotional tone
- Polished, clean mix

**Why**: Branded content needs to signal quality and professionalism. Audiences expect production value.

**Examples**: Product demos, brand videos, ads, sponsored content

### Tutorial/Educational

**Rule**: Dialogue-first, minimal music

- Clear, intelligible voice (no competing sounds)
- Music only in intro/outro or silent sections
- SFX for UI interactions and transitions
- Consistent volume throughout

**Why**: Educational content prioritizes information transfer. Any audio that competes with dialogue reduces comprehension.

**Examples**: How-to videos, courses, explainers

### Documentary/Cinematic

**Rule**: Rich soundscape, cinematic score

- Layered ambience for immersion
- Music score for emotional arc
- Foley for physical actions
- Dynamic range (quiet moments and loud moments)

**Why**: Documentary audiences expect immersive, cinematic audio that enhances storytelling.

**Examples**: Long-form YouTube documentaries, narrative content

## LUFS Levels Reference

LUFS (Loudness Units Full Scale) is the broadcast standard for measuring perceived loudness. Different content types and platforms have different target LUFS.

### Target LUFS by Content Type

| Content Type | Target LUFS | Notes |
|--------------|-------------|-------|
| YouTube | -14 to -16 | YouTube normalizes to -14 |
| Podcast | -16 to -19 | Spotify normalizes to -14 |
| TikTok/Shorts | -10 to -12 | Louder for mobile playback |
| Broadcast TV | -23 to -24 | EBU R128 standard |
| Streaming (Netflix) | -27 | Wide dynamic range |
| Audiobook | -18 to -23 | Consistent, comfortable |

### Layer LUFS Targets

| Layer | Target LUFS | Relative Level |
|-------|-------------|----------------|
| Dialogue | -15 | 0dB (reference) |
| Ambient | -25 | -10dB |
| SFX | -10 to -20 | Varies by effect |
| Music | -18 to -20 | -3 to -5dB |

**Measuring LUFS:**

```bash
# ffmpeg (integrated LUFS)
ffmpeg -i input.mp4 -af loudnorm=print_format=json -f null -

# Audacity: Analyze > Loudness Normalization (preview mode)
# DaVinci Resolve: Fairlight > Loudness Meter
# Adobe Audition: Effects > Amplitude and Compression > Match Loudness
```

**Normalization workflow:**

1. Mix all layers to target relative levels
2. Measure integrated LUFS of final mix
3. Apply loudness normalization to hit platform target
4. Use limiter to prevent clipping (true peak -1dB)

## Voice Tools Reference

### Local Voice Processing

**voice-helper.sh** - Interactive voice bridge for AI coding agent:

```bash
voice-helper.sh talk              # Start voice conversation (defaults)
voice-helper.sh talk whisper-mlx edge-tts  # Explicit engines
voice-helper.sh talk whisper-mlx macos-say # Offline mode
voice-helper.sh devices           # List audio devices
voice-helper.sh voices            # List available TTS voices
voice-helper.sh benchmark         # Test component speeds
```

**Architecture**: `Mic → Silero VAD → Whisper MLX (1.4s) → OpenCode run --attach (~4-6s) → Edge TTS (0.4s) → Speaker`

**Round-trip**: ~6-8s conversational, longer for tool execution.

### Cloud Voice Services

**ElevenLabs** (voice cloning, transformation):

- Voice cloning from 3-5 minute samples
- 29 languages, 100+ stock voices
- Emotional control and speaking style
- API: `elevenlabs-helper.sh` (if implemented)

**CapCut** (AI voice cleanup):

- Accent normalization
- Artifact removal
- Background noise reduction
- Web-based, no API (manual workflow)

**Edge TTS** (Microsoft, free):

- 400+ voices, 100+ languages
- Fast, low-latency
- No API key required
- Used by voice-helper.sh

### Speech-to-Speech Pipeline

For advanced use cases (custom LLMs, server/client deployment, multi-language, phone integration), see `tools/voice/speech-to-speech.md`.

**Pipeline**: `VAD → STT → LLM → TTS`

**Deployment modes**:

- Local (macOS with Apple Silicon)
- Local (CUDA GPU)
- Server/Client (Remote GPU)
- Docker (CUDA)

**Use cases**:

- Voice-driven DevOps
- Phone integration (Twilio)
- Video narration
- Multi-language support (6+ languages)

## Audio Production Workflow

### 1. Script Preparation

From `content/production/writing.md`:

- Long-form: Scene-by-scene with B-roll directions
- Short-form: Hook-first, 60s constraint
- Include emotional block cues for voice delivery
- Mark dialogue pacing (8-second chunks for AI video)

### 2. Voice Recording/Generation

**Option A: AI Voice (ElevenLabs)**

1. Generate voice from script with emotional blocks
2. Export as WAV (48kHz, 24-bit)
3. If from AI video: CapCut cleanup FIRST, then ElevenLabs

**Option B: Human Voice Actor**

1. Record in treated space (minimal reverb)
2. Use pop filter and quality mic
3. Record at -12dB to -18dB (leave headroom)
4. Provide emotional block cues as delivery notes

**Option C: Voice Cloning (Consistent Channel)**

1. Record or source 3-5 minute clean voice sample
2. Upload to ElevenLabs voice library
3. Use cloned voice for all channel content
4. Update voice sample quarterly for quality

### 3. Voice Cleanup (Layer 1)

```text
Raw Voice → Noise Reduction → EQ → Compression → De-esser → Limiter → -15 LUFS
```

**Tools**: CapCut (AI cleanup), Audacity (manual), Adobe Audition (pro)

### 4. Sound Design (Layers 2-4)

**Ambient (Layer 2)**:

- Source from Freesound, Epidemic Sound, or record custom
- Low-pass filter to avoid dialogue competition
- Target -25 LUFS

**SFX (Layer 3)**:

- Add whooshes for transitions
- Add impacts for reveals
- Time 1-2 frames before visual event
- Layer multiple SFX for bigger impacts

**Music (Layer 4)**:

- Select music matching content type and emotional tone
- Apply ducking (sidechain compression) to reduce volume during dialogue
- Target -18 to -20 LUFS

### 5. Mixing

**Balance**:

- Dialogue: 0dB (reference)
- Ambient: -10dB
- Music: -3 to -5dB
- SFX: Varies by effect

**Panning**:

- Dialogue: Center (mono)
- Ambient: Stereo width
- Music: Stereo
- SFX: Positioned to match visual

**EQ**:

- High-pass filter on all tracks (80Hz) to remove rumble
- Presence boost on dialogue (3-5kHz)
- Low-pass filter on ambient (8kHz) to avoid dialogue competition

### 6. Mastering

**Loudness normalization**:

1. Measure integrated LUFS of final mix
2. Apply loudness normalization to hit platform target
3. Use limiter to prevent clipping (true peak -1dB)

**Final export**:

- Format: WAV or AAC
- Sample rate: 48kHz (video standard)
- Bit depth: 24-bit (WAV) or 320kbps (AAC)
- Channels: Stereo (or mono for dialogue-only)

## Content Type Audio Presets

Quick-start presets for common content types:

### YouTube Long-Form

- **Dialogue**: -15 LUFS, centered, EQ for clarity
- **Music**: Upbeat royalty-free, -18 LUFS, ducking -6dB
- **SFX**: Transitions and reveals
- **Ambient**: Minimal or none

### TikTok/Shorts (UGC)

- **Dialogue**: -12 LUFS (louder for mobile), authentic/raw
- **Music**: Trending sounds (diegetic), no score
- **SFX**: Minimal, only for emphasis
- **Ambient**: Natural room tone

### Commercial/Product Demo

- **Dialogue**: -15 LUFS, professional voice (ElevenLabs)
- **Music**: Branded score, -20 LUFS, ducking -8dB
- **SFX**: UI sounds, product interactions
- **Ambient**: Designed ambience (not raw location)

### Podcast

- **Dialogue**: -16 to -19 LUFS, consistent volume
- **Music**: Intro/outro only, -18 LUFS
- **SFX**: Minimal, transitions only
- **Ambient**: None (studio environment)

### Documentary/Cinematic

- **Dialogue**: -15 LUFS, natural delivery
- **Music**: Cinematic score, -18 LUFS, ducking -4dB
- **SFX**: Rich foley, environmental sounds
- **Ambient**: Layered, immersive, -25 LUFS

## Integration with Content Pipeline

Audio production fits into the broader content creation pipeline:

```text
Research (content/research.md)
    ↓
Story (content/story.md)
    ↓
Script (content/production/writing.md)
    ↓
Voice Production (THIS FILE)
    ↓
Video Production (content/production/video.md)
    ↓
Final Mix & Master
    ↓
Distribution (content/distribution/)
```

**Cross-references**:

- **Script writing**: `content/production/writing.md` - Dialogue pacing, emotional cues
- **Video production**: `content/production/video.md` - Audio sync, dialogue timing
- **Voice tools**: `tools/voice/speech-to-speech.md` - Advanced voice pipeline
- **Voice helper**: `voice-helper.sh` - Local voice processing

## See Also

- `tools/voice/speech-to-speech.md` - Advanced voice pipeline (VAD, STT, LLM, TTS)
- `tools/voice/cloud-voice-agents.md` - Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/voice-ai-models.md` - Complete model comparison (TTS, STT, S2S)
- `tools/voice/pipecat-opencode.md` - Pipecat real-time voice pipeline
- `tools/video/remotion.md` - Video narration and compositing
- `tools/video/heygen-skill/rules/voices.md` - AI voice cloning
- `content/production/writing.md` - Script structure and dialogue pacing
- `content/production/video.md` - Video production and audio sync
- `content/optimization.md` - A/B testing audio variants
