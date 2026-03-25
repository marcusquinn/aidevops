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
- **Pipeline Helper**: `voice-pipeline-helper.sh [pipeline|extract|cleanup|transform|normalize|tts|voices|clone|status]`
- **Voice Bridge**: `voice-helper.sh [talk|devices|voices|benchmark]`
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

1. **CapCut AI Voice Cleanup** (FIRST): Normalizes accents/artifacts, removes robotic patterns, cleans background noise, standardizes volume and tone.
2. **ElevenLabs Transformation** (SECOND): Voice cloning, emotional delivery, character consistency, professional quality.

**Common mistake**: Feeding raw AI video audio directly to ElevenLabs amplifies artifacts during transformation.

### Voice Cloning Workflow

```bash
# Voice bridge for interactive voice (development/testing)
voice-helper.sh talk              # Start voice conversation
voice-helper.sh voices            # List available TTS voices
```

**Critical: NEVER use pre-made ElevenLabs voices for realistic content.** Pre-made voices are widely recognised and signal "AI-generated". Instead:

- **Voice Design**: Create from natural language description (e.g., "warm female voice, mid-30s, slight British accent")
- **Instant Voice Clone**: Upload a 10-30 second clean audio clip
- **Professional Voice Clone**: Upload 3-5 minutes for highest fidelity (recommended for AI influencer personas)

**Voice cloning source quality rules**: Single speaker, quiet environment, clear pronunciation. If cloning from existing content, run through CapCut cleanup first.

**Alternative: MiniMax TTS** — For talking-head content where ElevenLabs is overkill. Good default quality at $5/month for 120 minutes; voice clone works with a 10-second clip. See `tools/voice/voice-models.md`.

**Voice consistency checklist:**

- [ ] Same voice model across all channel content
- [ ] NEVER use pre-made voices for realism content
- [ ] Consistent speaking pace (words per minute)
- [ ] Matching emotional tone for content type
- [ ] Standardized pronunciation for brand terms
- [ ] Voice sample updated quarterly for quality

### Emotional Block Cues

Per-word emotion tagging for natural AI speech delivery. Dramatically improves naturalness by giving TTS explicit emotional context.

**Format:**

```text
[neutral]Welcome to the channel.[/neutral] [excited]Today we're covering something amazing![/excited] [serious]But first, let's understand the problem.[/serious]
```

**Available emotion tags:**

| Tag | Use Case |
|-----|----------|
| `[neutral]` | Default, informational |
| `[excited]` | Hooks, reveals, wins |
| `[serious]` | Problems, warnings, data |
| `[curious]` | Questions, exploration |
| `[confident]` | Authority, expertise |
| `[empathetic]` | Pain points, struggles |
| `[urgent]` | CTAs, time-sensitive |

**Emotional pacing rules:**

1. **Hook (0-3s)**: `[excited]` or `[curious]`
2. **Problem (3-10s)**: `[serious]` or `[empathetic]`
3. **Solution (10s+)**: `[confident]`
4. **CTA (final 5s)**: `[urgent]` or `[excited]`

Scripts from `content/production/writing.md` should include emotional block markup. TTS engines with emotion support (ElevenLabs, ChatTTS) parse these directly.

## 4-Layer Audio Design

### Layer 1: Dialogue (Primary) — Target: -15 LUFS

Processing chain: `Raw Voice → Noise Reduction → EQ → Compression → De-esser → Limiter → -15 LUFS`

- Always centered (mono or center channel)
- EQ: High-pass filter at 80Hz, presence boost at 3-5kHz
- Tools: CapCut (AI cleanup), ElevenLabs (transformation), Audacity/Audition (manual), `voice-helper.sh`

### Layer 2: Ambient Noise (Background) — Target: -25 LUFS

- Stereo width for immersion; low-pass filter to avoid competing with dialogue

| Content Type | Ambient Style |
|--------------|---------------|
| UGC/Vlog | Diegetic only (room tone, keyboard clicks) |
| Tutorial | Minimal/none |
| Documentary | Rich environmental |
| Commercial | Designed ambience |

Sources: Freesound.org (CC0/CC-BY), Epidemic Sound, custom recording, AI-generated (AudioCraft, Stable Audio).

### Layer 3: SFX (Sound Effects) — Target: -10 to -20 LUFS

Categories: Whooshes/Swooshes, Impacts, UI Sounds, Foley, Risers/Drops.

**Timing rules**: SFX should land 1-2 frames BEFORE the visual event. Layer multiple SFX for bigger impacts. Use reverb to place SFX in the same "space" as dialogue.

### Layer 4: Music (Score) — Target: -18 to -20 LUFS

| Content Type | Music Style | Ducking |
|--------------|-------------|---------|
| UGC | All diegetic (no score) | N/A |
| Tutorial | Minimal, ambient | -6dB during speech |
| Commercial | Mixed diegetic + score | -8dB during speech |
| Documentary | Cinematic score | -4dB during speech |
| YouTube | Upbeat, royalty-free | -6dB during speech |

Sources: Epidemic Sound, Artlist, Uppbeat (free tier), AudioJungle, AI-generated (Suno, Udio, Stable Audio).

**Ducking automation**: Set dialogue track as sidechain input, music as target. Threshold -20dB, ratio 4:1, attack 10ms, release 200ms.

## LUFS Reference

### Platform Targets

| Content Type | Target LUFS | Notes |
|--------------|-------------|-------|
| YouTube | -14 to -16 | YouTube normalizes to -14 |
| Podcast | -16 to -19 | Spotify normalizes to -14 |
| TikTok/Shorts | -10 to -12 | Louder for mobile playback |
| Broadcast TV | -23 to -24 | EBU R128 standard |
| Streaming (Netflix) | -27 | Wide dynamic range |
| Audiobook | -18 to -23 | Consistent, comfortable |

### Layer Targets

| Layer | Target LUFS |
|-------|-------------|
| Dialogue | -15 (reference) |
| Ambient | -25 |
| SFX | -10 to -20 |
| Music | -18 to -20 |

**Measuring LUFS:**

```bash
ffmpeg -i input.mp4 -af loudnorm=print_format=json -f null -
# Audacity: Analyze > Loudness Normalization (preview mode)
# DaVinci Resolve: Fairlight > Loudness Meter
```

**Normalization workflow**: Mix layers → measure integrated LUFS → apply normalization → limiter (true peak -1dB).

## Platform Audio Rules

| Platform | Rule | Why |
|----------|------|-----|
| UGC (TikTok, Shorts) | All diegetic, no score | Raw/authentic feel; polished audio breaks trust |
| Commercial/Branded | Mixed diegetic + score, professional voice | Signals quality and production value |
| Tutorial/Educational | Dialogue-first, minimal music | Competing audio reduces comprehension |
| Documentary/Cinematic | Rich soundscape, cinematic score | Immersive storytelling |

## Voice Tools Reference

### Local Voice Processing

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

**ElevenLabs**: Voice cloning from 3-5 min samples, 29 languages, 100+ stock voices, emotional control. API: `voice-pipeline-helper.sh [transform|tts|voices|clone]`

**CapCut-equivalent cleanup** (local ffmpeg): Noise reduction, high-pass filter, de-essing, loudness normalization. CLI: `voice-pipeline-helper.sh cleanup <audio> [output] [target-lufs]`

**Edge TTS** (Microsoft, free): 400+ voices, 100+ languages, fast, no API key. Used by voice-helper.sh.

For advanced use cases (custom LLMs, server/client deployment, phone integration), see `tools/voice/speech-to-speech.md`.

## See Also

- `tools/voice/speech-to-speech.md` — Advanced voice pipeline (VAD, STT, LLM, TTS)
- `tools/voice/cloud-voice-agents.md` — Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/voice-ai-models.md` — Complete model comparison (TTS, STT, S2S)
- `tools/voice/voice-models.md` — TTS model comparison (ElevenLabs, MiniMax, Qwen3-TTS)
- `tools/voice/pipecat-opencode.md` — Pipecat real-time voice pipeline
- `content/production/writing.md` — Script structure, dialogue pacing, emotional cues
- `content/production/video.md` — Video production and audio sync
- `content/optimization.md` — A/B testing audio variants
