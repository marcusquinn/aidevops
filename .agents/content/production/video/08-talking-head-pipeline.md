# Longform Talking-Head Pipeline (30s+)

Audio-driven pipeline — voice audio controls lip movement and timing.

```text
Starting Image → Script → Voice Audio → Talking-Head Video → Post-Processing
     (1)           (2)        (3)              (4)                (5)
```

## Step 1: Starting Image

Use Nanobanana Pro with JSON prompts (see `content/production/image.md`) for precise color grading. The JSON `color` and `lighting` fields prevent flat greyscale output. Video models amplify any source artifacts — use high-resolution, photorealistic images.

Tool routing: Character/person → Nanobanana Pro or Freepik; 4K refinement → Seedream 4; face consistency across series → Ideogram face swap.

## Step 2: Script

Write for natural speech, not written text:

- Contractions: "it's", "don't", "we're" — never "it is", "do not"
- Short sentences: 8-12 words for natural pacing
- Emotional block cues: `[excited]This changed how I work.[/excited]`
- Read-aloud test: if it sounds awkward spoken, rewrite it

## Step 3: Voice Audio

**This is the most important step.** Robotic audio gets scrolled past immediately.

| Tool | Quality | Cost | Voice Clone | Best For |
|------|---------|------|-------------|----------|
| **ElevenLabs** | Highest | $5-99/mo | Yes (10-30s clip) | Maximum realism, custom voices |
| **MiniMax TTS** | High | $5/mo (120 min) | Yes (10s clip) | Easiest setup, best value |
| **Qwen3-TTS** | High | Free (local, CUDA) | Yes (3s clip) | Self-hosted, open source |

**NEVER use pre-made ElevenLabs voices** for realism — widely recognised as AI. Use Voice Design or Instant Voice Clone. For cloning: quiet room, single speaker, no background music. Run through CapCut cleanup pipeline first if cloning from existing content (see `content/production/audio.md`).

MiniMax: best quality-to-effort ratio, natural-sounding by default, $5/month for 120 minutes. Qwen3-TTS: 97ms streaming latency, instruction-controlled emotion — see `tools/voice/qwen3-tts.md`.

## Step 4: Talking-Head Video

| Model | Quality | Cost | Best For |
|-------|---------|------|----------|
| **HeyGen Avatar 4** | High | Subscription | Best all-around, easiest workflow |
| **VEED Fabric 1.0** | Highest | Higher | Maximum quality, premium content |
| **InfiniteTalk** | Good | Free (self-hosted) | Budget/self-hosted |

HeyGen: upload starting image as photo avatar, upload voice audio, generate. See `video/heygen-skill.md`. VEED: via MuAPI lipsync endpoint `POST /api/v1/veed-lipsync` (see `video/muapi.md`).

## Step 5: Post-Processing

1. Upscale if needed: `real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2`
2. Denoise: `real-video-enhancer-helper.sh denoise input.mp4 output.mp4`
3. Film grain: subtle grain for organic aesthetic
4. Audio mix: layer ambient sound and music behind voice (see `content/production/audio.md` 4-Layer Audio Design)

## Longform Assembly (30s+)

```bash
# Split script into segments matching model's max duration (e.g., 10s for HeyGen)
# Generate each segment with same starting image and voice settings
# Stitch segments:
printf "file '%s'\n" segment_*.mp4 > concat.txt
ffmpeg -f concat -safe 0 -i concat.txt -c copy longform_output.mp4
# Add B-roll cuts between segments to hide transition artifacts
# Replace stitched audio with original full-length voice track for seamless continuity
```

## Use Case Routing

| Use Case | Starting Image | Voice | Video Model | Post-Processing |
|----------|---------------|-------|-------------|-----------------|
| Paid ads | Nanobanana Pro (brand colors) | ElevenLabs (custom clone) | VEED Fabric | Full pipeline |
| Organic social | Nanobanana Pro or Freepik | MiniMax (default voice) | HeyGen Avatar 4 | Light denoise |
| AI influencer | Nanobanana Pro (consistent character) | ElevenLabs (cloned persona) | HeyGen Avatar 4 | Film grain + upscale |
| Budget/volume | Freepik | Qwen3-TTS (local) | InfiniteTalk | Minimal |
