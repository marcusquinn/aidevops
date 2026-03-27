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

- **Pipeline**: Voice cleanup → Voice transformation → Sound design → Mixing
- **Key Rule**: ALWAYS clean AI voice output with CapCut BEFORE ElevenLabs transformation
- **Pipeline Helper**: `voice-pipeline-helper.sh [pipeline|extract|cleanup|transform|normalize|tts|voices|clone|status]`
- **Voice Bridge**: `voice-helper.sh [talk|devices|voices|benchmark]`
- **References**: `tools/voice/speech-to-speech.md`, `voice-helper.sh`

<!-- AI-CONTEXT-END -->

## Voice Production Pipeline

### Critical 2-Step Voice Workflow

**NEVER go directly from AI video output to ElevenLabs.** Raw AI audio fed to ElevenLabs amplifies artifacts.

```text
AI Video Output → CapCut AI Voice Cleanup → ElevenLabs Transformation → Final Audio
```

1. **CapCut AI Voice Cleanup** (FIRST): Normalizes accents/artifacts, removes robotic patterns, cleans noise, standardizes volume.
2. **ElevenLabs Transformation** (SECOND): Voice cloning, emotional delivery, character consistency.

### Voice Cloning

**NEVER use pre-made ElevenLabs voices for realistic content** — they're widely recognised as AI-generated. Instead:

- **Voice Design**: Create from natural language description (e.g., "warm female voice, mid-30s, slight British accent")
- **Instant Voice Clone**: Upload a 10-30 second clean audio clip
- **Professional Voice Clone**: Upload 3-5 minutes for highest fidelity (recommended for AI influencer personas)

Source quality: single speaker, quiet environment, clear pronunciation. Run existing content through CapCut cleanup first. **Alternative: MiniMax TTS** — $5/month for 120 min, 10-second clone, good for talking-head content. See `tools/voice/voice-models.md`.

**Voice consistency**: Same voice model across all content; consistent pace, tone, and brand-term pronunciation; update sample quarterly.

### Emotional Block Cues

Per-word emotion tagging for natural AI speech. TTS engines with emotion support (ElevenLabs, ChatTTS) parse these directly.

```text
[neutral]Welcome to the channel.[/neutral] [excited]Today we're covering something amazing![/excited] [serious]But first, let's understand the problem.[/serious]
```

| Tag | Use Case |
|-----|----------|
| `[neutral]` | Default, informational |
| `[excited]` | Hooks (0-3s), reveals, wins |
| `[serious]` | Problems (3-10s), warnings, data |
| `[curious]` | Questions, exploration |
| `[confident]` | Authority, expertise (10s+) |
| `[empathetic]` | Pain points, struggles |
| `[urgent]` | CTAs (final 5s), time-sensitive |

Scripts from `content/production/writing.md` should include emotional block markup.

## 4-Layer Audio Design

### Layer 1: Dialogue (Primary) — Target: -15 LUFS

Processing: `Raw Voice → Noise Reduction → EQ → Compression → De-esser → Limiter → -15 LUFS`

- Centered (mono or center channel); EQ: high-pass at 80Hz, presence boost at 3-5kHz
- Tools: CapCut (AI cleanup), ElevenLabs (transformation), Audacity/Audition (manual), `voice-helper.sh`

### Layer 2: Ambient Noise (Background) — Target: -25 LUFS

Stereo width for immersion; low-pass filter to avoid competing with dialogue. Style by type: UGC/Vlog → diegetic only; Tutorial → minimal/none; Documentary → rich environmental; Commercial → designed ambience.

Sources: Freesound.org (CC0/CC-BY), Epidemic Sound, custom recording, AI-generated (AudioCraft, Stable Audio).

### Layer 3: SFX (Sound Effects) — Target: -10 to -20 LUFS

Categories: Whooshes/Swooshes, Impacts, UI Sounds, Foley, Risers/Drops.

**Timing**: SFX land 1-2 frames BEFORE the visual event. Layer multiple SFX for bigger impacts. Use reverb to place SFX in the same "space" as dialogue.

### Layer 4: Music (Score) — Target: -18 to -20 LUFS

| Content Type | Music Style | Ducking |
|--------------|-------------|---------|
| UGC | All diegetic (no score) | N/A |
| Tutorial | Minimal, ambient | -6dB during speech |
| Commercial | Mixed diegetic + score | -8dB during speech |
| Documentary | Cinematic score | -4dB during speech |
| YouTube | Upbeat, royalty-free | -6dB during speech |

Sources: Epidemic Sound, Artlist, Uppbeat (free tier), AudioJungle, AI-generated (Suno, Udio, Stable Audio).

**Ducking**: Dialogue as sidechain input, music as target. Threshold -20dB, ratio 4:1, attack 10ms, release 200ms.

## LUFS Reference

| Platform | Target LUFS | Notes |
|----------|-------------|-------|
| YouTube | -14 to -16 | Normalizes to -14 |
| Podcast | -16 to -19 | Spotify normalizes to -14 |
| TikTok/Shorts | -10 to -12 | Louder for mobile |
| Broadcast TV | -23 to -24 | EBU R128 |
| Streaming (Netflix) | -27 | Wide dynamic range |
| Audiobook | -18 to -23 | Consistent, comfortable |

**Measuring LUFS:**

```bash
ffmpeg -i input.mp4 -af loudnorm=print_format=json -f null -
# Audacity: Analyze > Loudness Normalization (preview mode)
# DaVinci Resolve: Fairlight > Loudness Meter
```

Mix layers → measure integrated LUFS → apply normalization → limiter (true peak -1dB).

## Voice Tools Reference

```bash
voice-helper.sh talk              # Start voice conversation (defaults)
voice-helper.sh talk whisper-mlx edge-tts  # Explicit engines
voice-helper.sh talk whisper-mlx macos-say # Offline mode
voice-helper.sh devices           # List audio devices
voice-helper.sh voices            # List available TTS voices
voice-helper.sh benchmark         # Test component speeds
```

**Architecture**: `Mic → Silero VAD → Whisper MLX (1.4s) → OpenCode (~4-6s) → Edge TTS (0.4s) → Speaker` (~6-8s round-trip)

**ElevenLabs**: Voice cloning (3-5 min samples), 29 languages, emotional control. API: `voice-pipeline-helper.sh [transform|tts|voices|clone]`

**CapCut-equivalent cleanup** (local ffmpeg): Noise reduction, high-pass, de-essing, normalization. CLI: `voice-pipeline-helper.sh cleanup <audio> [output] [target-lufs]`

**Edge TTS** (Microsoft, free): 400+ voices, 100+ languages, no API key. Used by voice-helper.sh.

Advanced use cases (custom LLMs, server/client, phone): `tools/voice/speech-to-speech.md`.

## See Also

- `tools/voice/speech-to-speech.md` — Advanced voice pipeline (VAD, STT, LLM, TTS)
- `tools/voice/cloud-voice-agents.md` — Cloud voice agents (GPT-4o Realtime, MiniCPM-o)
- `tools/voice/voice-ai-models.md` — Complete model comparison (TTS, STT, S2S)
- `tools/voice/voice-models.md` — TTS model comparison (ElevenLabs, MiniMax, Qwen3-TTS)
- `tools/voice/pipecat-opencode.md` — Pipecat real-time voice pipeline
- `content/production/writing.md` — Script structure, dialogue pacing, emotional cues
- `content/production/video.md` — Video production and audio sync
- `content/optimization.md` — A/B testing audio variants
