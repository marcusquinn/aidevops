---
description: "AI video generation - Sora 2, Veo 3.1, Higgsfield, seed bracketing, and production workflows"
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

# AI Video Production

<!-- CLASSIFICATION: Domain reference material (not agent operational instructions).
     This file documents video production techniques, API workflows, prompt templates,
     and tool comparisons. Imperative language ("ALWAYS use ingredients-to-video",
     "NEVER frame-to-video") describes domain best practices, not agent behaviour
     directives. The single-source-of-truth policy (AGENTS.md) governs agent routing,
     tool access, and behavioural rules — not domain knowledge libraries like this.
     See AGENTS.md Domain Index: Content/Video/Voice for the authoritative pointer. -->

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary Models**: Sora 2 Pro (UGC/authentic, <$10k), Veo 3.1 (cinematic/character-consistent, >$100k)
- **Key Technique**: Seed bracketing (15% → 70%+ success rate)
- **Seed ranges**: people 1000-1999, action 2000-2999, landscape 3000-3999, product 4000-4999, YouTube 2000-3000
- **2-Track production**: objects/environments (Midjourney→VEO) vs characters (Freepik→Seedream→VEO)
- **Veo 3.1**: ALWAYS use ingredients-to-video, NEVER frame-to-video (produces grainy yellow output)

**Model Selection**:

```text
Content Type?
├─ UGC/Authentic/Social (<$10k)  → Sora 2 Pro
├─ Cinematic/Commercial (>$100k) → Veo 3.1
└─ Character-Consistent Series   → Veo 3.1 (with Ingredients)
```

<!-- AI-CONTEXT-END -->

## Sora 2 Pro Master Template

Sora 2 excels at UGC-style, authentic content. Use the 6-section master template for professional results.

```text
[1. HEADER - Style Definition (7 parameters)]
Style: [aesthetic], [mood], [color palette], [lighting], [texture], [era/period], [cultural context]

[2. SHOT-BY-SHOT BREAKDOWN - Cinematography Spec (5 points each)]
Shot 1 (0-2s):
- Type: [ECU/CU/MCU/MS/MWS/WS/EWS]
- Angle: [eye-level/high/low/dutch/overhead/POV]
- Movement: [static/dolly/pan/tracking/handheld/crane]
- Focus: [subject/background/rack focus]
- Composition: [rule of thirds/centered/leading lines/symmetry]

[3. TIMESTAMPED ACTIONS - 0.5s intervals]
0.0s: [precise action description]
0.5s: [micro-movement or expression change]
[continue through full duration]

[4. DIALOGUE - Delivery Style]
Character: "Exact dialogue text"
Delivery: [tone, pacing, emotion, emphasis]
Duration: [8-second rule: 12-15 words, 20-25 syllables max]

[5. BACKGROUND SOUND - 4-Layer Audio Design]
Layer 1 (Dialogue): [voice characteristics, clarity]
Layer 2 (Ambient): [environment noise at -25 LUFS]
Layer 3 (SFX): [specific sound effects with timing]
Layer 4 (Music): [score/diegetic, mood, volume]

[6. TECHNICAL SPECS FOOTER]
Duration: [total seconds]
Aspect Ratio: [16:9/9:16/1:1]
Resolution: [1080p/4K/8K]
Frame Rate: [24fps/30fps/60fps - 60fps for action only]
Camera Model: [RED Komodo 6K / ARRI Alexa LF / Sony Venice 8K]
Negative Prompt: subtitles, captions, watermark, text overlays, poor lighting, blurry footage, artifacts, distorted hands
```

### Example: Product Demo (UGC Style)

```text
[1. HEADER]
Style: authentic, energetic, warm natural tones, soft window lighting, organic texture, contemporary 2024, creator economy aesthetic

[2. SHOT-BY-SHOT]
Shot 1 (0-3s): MCU, eye-level slightly off-center, handheld natural shake, shallow DOF, rule of thirds
Shot 2 (3-6s): CU on product, overhead 45-degree, slow dolly in, rack focus to hands, centered

[3. TIMESTAMPED ACTIONS]
0.0s: Creator looks at camera, genuine smile forming
0.5s: Picks up product with right hand
1.0s: Holds product at chest level, slight rotation
1.5s: Left hand gestures toward feature
2.0s: Camera shifts to overhead view
2.5s-5.5s: Hands demonstrate use, creator face re-enters, maintains eye contact

[4. DIALOGUE]
Creator: "This completely changed how I work. The build quality is incredible, and it just works."
Delivery: Conversational, authentic enthusiasm, natural pacing
Duration: 6 seconds (14 words, 22 syllables)

[5. BACKGROUND SOUND]
Layer 1: Clear voice, warm tone, -15 LUFS
Layer 2: Quiet home office, distant keyboard, -25 LUFS
Layer 3: Product pickup (0.5s), handling sounds (2.5s-4.0s)
Layer 4: None (UGC authenticity)

[6. TECHNICAL SPECS]
Duration: 6s | Aspect Ratio: 9:16 | Resolution: 1080p | Frame Rate: 30fps
Camera Model: iPhone 15 Pro aesthetic (UGC authenticity)
Negative Prompt: subtitles, captions, watermark, professional studio lighting, corporate aesthetic, distorted hands
```

## Veo 3.1 Production Workflow

Veo 3.1 excels at cinematic, character-consistent content. **CRITICAL**: Always use ingredients-to-video, NEVER frame-to-video.

### VEO Prompting Framework (7 Components)

```text
[1. TECHNICAL SPECS] Camera: [model/lens], [resolution], [frame rate], [aspect ratio] | Lighting | Movement
[2. SUBJECT] Character: [15+ attributes for consistency] OR Object: [detailed description]
[3. ACTION] Primary: [main movement] | Secondary: [supporting actions] | Timing: [pacing, beats]
[4. CONTEXT] Environment: [location, time, weather] | Props | Atmosphere
[5. CAMERA MOVEMENT] Type | Path: [direction, speed, focal changes] | Motivation
[6. COMPOSITION] Framing: [shot type] | Depth: [foreground/midground/background] | Visual Hierarchy
[7. AUDIO] Dialogue: [exact words, delivery] (NO SUBTITLES in prompt) | Ambient | SFX | Music
```

### Ingredients-to-Video Workflow (MANDATORY)

**CRITICAL**: Frame-to-video produces grainy, yellow-tinted output. Always use ingredients.

**Step 1**: Upload reference assets as "ingredients" (character faces, product images, brand assets, style references).

```bash
# Create ingredient via Higgsfield API
curl -X POST 'https://platform.higgsfield.ai/api/characters' \
  --header 'hf-api-key: {api-key}' --header 'hf-secret: {secret}' \
  --form 'photo=@/path/to/character_face.jpg'
# Returns: {"id": "3eb3ad49-775d-40bd-b5e5-38b105108780", "photo_url": "..."}
```

**Step 2**: Generate with ingredient:

```json
{
  "params": {
    "prompt": "[Full VEO 7-component prompt]",
    "custom_reference_id": "3eb3ad49-775d-40bd-b5e5-38b105108780",
    "custom_reference_strength": 0.9,
    "model": "veo-3.1-pro"
  }
}
```

**Ingredient strength**: 0.7-0.8 = subtle influence; 0.9-1.0 = strong consistency. Character faces: 0.9+, Products: 0.95+, Style references: 0.7-0.8.

## Seed Bracketing Method

Increases success rate from 15% to 70%+ by systematically testing seed ranges.

**Step 1**: Select seed range by content type (people 1000-1999, action 2000-2999, landscape 3000-3999, product 4000-4999).

**Step 2**: Generate 10-15 variations with sequential seeds:

```bash
#!/bin/bash
set -euo pipefail
for seed in {4000..4010}; do
  result=$(curl --fail --show-error --silent -X POST \
    'https://platform.higgsfield.ai/v1/image2video/dop' \
    --header 'hf-api-key: {api-key}' --header 'hf-secret: {secret}' \
    --data "{\"params\":{\"prompt\":\"[your prompt]\",\"seed\":$seed,\"model\":\"dop-turbo\"}}") \
    || { echo "ERROR: API call failed for seed $seed" >&2; continue; }
  job_id=$(echo "$result" | jq -r '.jobs[0].id // empty' || true)
  [[ -z "$job_id" ]] && { echo "ERROR: No job_id for seed $seed" >&2; continue; }
  echo "$seed,$job_id" >> seed_bracket_results.csv
done
```

**Step 3**: Score outputs (1-10 scale): Composition 25%, Quality 25%, Style Adherence 20%, Motion Realism 20%, Subject Accuracy 10%.

**Step 4**: Score 8.0+ = production-ready; 6.5-7.9 = acceptable; <6.5 = discard. If no winners, shift to adjacent range (+/- 100) or revise prompt.

### Automation

```bash
seed-bracket-helper.sh generate --type product --prompt "Product rotating on white background"
seed-bracket-helper.sh status
seed-bracket-helper.sh score 4005 8 9 7 8 9
seed-bracket-helper.sh report
seed-bracket-helper.sh presets
```

## 8K Camera Model Prompting

| Camera | Aesthetic | Use Case |
|--------|-----------|----------|
| **RED Komodo 6K** | Digital cinema, sharp | Action, sports, high-motion |
| **ARRI Alexa LF** | Film-like, organic | Drama, narrative, skin tones |
| **Sony Venice 8K** | Clean, clinical | Commercial, product, precision |
| **Blackmagic URSA 12K** | Raw, flexible | Indie, experimental |
| **Canon C500 Mark II** | Smooth, polished | Corporate, documentary |

**Lens characteristics**: 35mm Anamorphic (cinematic, oval bokeh, 2.39:1), 50mm Prime (natural, sharp), 24mm Wide (expansive), 85mm Portrait (flattering, compressed), 14mm Ultra-Wide (dramatic).

## 2-Track Production Workflow

**Track 1 (Objects & Environments)**: Midjourney → Veo 3.1

```text
/imagine [object/environment description] --ar 16:9 --style raw --v 6
```

Upload Midjourney output as ingredient, apply VEO framework for animation.

**Track 2 (Characters & People)**: Freepik → Seedream 4 → Veo 3.1

```bash
# Refine to 4K via Higgsfield API
curl -X POST 'https://platform.higgsfield.ai/bytedance/seedream/v4/upscale' \
  --header 'Authorization: Key {api_key}:{api_secret}' \
  --data '{"image_url": "https://freepik-output.jpg", "target_resolution": "4K"}'
```

| Content Type | Track | Reason |
|--------------|-------|--------|
| Product demo | Track 1 | Objects, no facial consistency needed |
| Landscape flythrough | Track 1 | Environment, no characters |
| Talking head | Track 2 | Facial expressions, character consistency |
| Mixed (character + product) | Both | Generate separately, composite in post |

## Content Type Presets

| Format | Aspect | Duration | Camera | Model | Seed Range |
|--------|--------|----------|--------|-------|------------|
| UGC | 9:16 | 3-10s | Handheld | Sora 2 Pro | 2000-3000 |
| Commercial | 16:9 | 15-30s | Gimbal | Veo 3.1 | 4000-4999 (product) / 1000-1999 (people) |
| Cinematic | 2.39:1 | 10-30s | Dolly/crane | Veo 3.1 | 3000-3999 / 1000-1999 |
| Documentary | 16:9 | 15-60s | Tripod/handheld | Sora 2 Pro or Veo 3.1 | 2000-2999 / 3000-3999 |

## Post-Production Guidelines

### Upscaling

**REAL Video Enhancer** (open-source, GPU-accelerated):

```bash
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 4 --model realesrgan
# Models: span (fast, default), realesrgan (photo-realistic), animejanai (animation)
```

**Topaz Video AI** (commercial): Max 1.25-1.75x upscale. Settings: Artemis High Quality, low noise reduction, minimal sharpening, grain preservation on. 4K→8K NOT RECOMMENDED.

### Frame Rate Conversion

```bash
real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 --fps 60
# Models: rife (fast, default), gmfss (very high quality), ifrnet (very fast)
```

**CRITICAL**: Never upconvert 24fps to 60fps for non-action content (creates soap opera effect).

### Denoising and Full Enhancement Pipeline

```bash
real-video-enhancer-helper.sh denoise input.mp4 output.mp4
# All-in-one for social media delivery:
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 --scale 2 --fps 60 --denoise
```

### Film Grain

Add subtle grain for organic, less-AI-detected aesthetic. DaVinci Resolve settings: grain_size 0.5-0.8, intensity 5-10%, color_variation 2-5%. Always for cinematic; optional for UGC; selective for commercial.

See `tools/video/real-video-enhancer.md` for full documentation.

## Shot Type Reference

| Abbreviation | Name | Framing | Use Case |
|--------------|------|---------|----------|
| EWS | Extreme Wide Shot | Full environment, subject tiny | Establishing, scale |
| WS | Wide Shot | Full body | Subject in context |
| MS | Medium Shot | Waist up | Standard conversation |
| MCU | Medium Close-Up | Chest up | Emotional connection |
| CU | Close-Up | Head and shoulders | Emotion, intimacy |
| ECU | Extreme Close-Up | Eyes, mouth, hands | Intense emotion, detail |

**Camera angles**: Eye-Level (neutral), High Angle (vulnerability), Low Angle (power), Dutch (unease), Overhead (observation), POV (immersion).

**Camera movements**: Static (stability), Pan (horizontal reveal), Tilt (vertical reveal), Dolly In/Out (intimacy/context), Tracking (energy), Crane (drama), Handheld (authenticity), Gimbal (cinematic).

## Model Comparison

| Model | Strengths | Limitations | Best For |
|-------|-----------|-------------|----------|
| **Sora 2 Pro** | Authentic UGC, fast (<2 min), lower cost, natural movement | Max 10s, less cinematography control, 1080p native | TikTok, Reels, Shorts, testimonials |
| **Veo 3.1** | Cinematic quality, character consistency, 8K, precise control | Slower (5-10 min), higher cost, complex prompting | Commercials, brand content, character series |
| **Higgsfield** | 100+ models via single API, Kling/Seedance/DOP, webhook support | API-based only, model availability varies | Automated pipelines, batch generation, A/B testing |

## Longform Talking-Head Pipeline (30s+)

Audio-driven pipeline — voice audio controls lip movement and timing.

```text
Starting Image → Script → Voice Audio → Talking-Head Video → Post-Processing
     (1)           (2)        (3)              (4)                (5)
```

### Step 1: Starting Image

Use Nanobanana Pro with JSON prompts (see `content/production/image.md`) for precise color grading. The JSON `color` and `lighting` fields prevent flat greyscale output. Video models amplify any source artifacts — use high-resolution, photorealistic images.

Tool routing: Character/person → Nanobanana Pro or Freepik; 4K refinement → Seedream 4; face consistency across series → Ideogram face swap.

### Step 2: Script

Write for natural speech, not written text:
- Contractions: "it's", "don't", "we're" — never "it is", "do not"
- Short sentences: 8-12 words for natural pacing
- Emotional block cues: `[excited]This changed how I work.[/excited]`
- Read aloud test: if it sounds awkward spoken, rewrite it

### Step 3: Voice Audio

**This is the most important step.** Robotic audio gets scrolled past immediately.

| Tool | Quality | Cost | Voice Clone | Best For |
|------|---------|------|-------------|----------|
| **ElevenLabs** | Highest | $5-99/mo | Yes (10-30s clip) | Maximum realism, custom voices |
| **MiniMax TTS** | High | $5/mo (120 min) | Yes (10s clip) | Easiest setup, best value |
| **Qwen3-TTS** | High | Free (local, CUDA) | Yes (3s clip) | Self-hosted, open source |

**NEVER use pre-made ElevenLabs voices** for realism — widely recognised as AI. Use Voice Design or Instant Voice Clone. For cloning: quiet room, single speaker, no background music. Run through CapCut cleanup pipeline first if cloning from existing content (see `content/production/audio.md`).

MiniMax: best quality-to-effort ratio, natural-sounding by default, $5/month for 120 minutes. Qwen3-TTS: 97ms streaming latency, instruction-controlled emotion — see `tools/voice/qwen3-tts.md`.

### Step 4: Talking-Head Video

| Model | Quality | Cost | Best For |
|-------|---------|------|----------|
| **HeyGen Avatar 4** | High | Subscription | Best all-around, easiest workflow |
| **VEED Fabric 1.0** | Highest | Higher | Maximum quality, premium content |
| **InfiniteTalk** | Good | Free (self-hosted) | Budget/self-hosted |

HeyGen: upload starting image as photo avatar, upload voice audio, generate. See `tools/video/heygen-skill.md`. VEED: via MuAPI lipsync endpoint `POST /api/v1/veed-lipsync` (see `tools/video/muapi.md`).

### Step 5: Post-Processing

1. Upscale if needed: `real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2`
2. Denoise: `real-video-enhancer-helper.sh denoise input.mp4 output.mp4`
3. Film grain: subtle grain for organic aesthetic
4. Audio mix: layer ambient sound and music behind voice (see `content/production/audio.md` 4-Layer Audio Design)

### Longform Assembly (30s+)

```bash
# Split script into segments matching model's max duration (e.g., 10s for HeyGen)
# Generate each segment with same starting image and voice settings
# Stitch segments:
printf "file '%s'\n" segment_*.mp4 > concat.txt
ffmpeg -f concat -safe 0 -i concat.txt -c copy longform_output.mp4
# Add B-roll cuts between segments to hide transition artifacts
# Replace stitched audio with original full-length voice track for seamless continuity
```

### Use Case Routing

| Use Case | Starting Image | Voice | Video Model | Post-Processing |
|----------|---------------|-------|-------------|-----------------|
| Paid ads | Nanobanana Pro (brand colors) | ElevenLabs (custom clone) | VEED Fabric | Full pipeline |
| Organic social | Nanobanana Pro or Freepik | MiniMax (default voice) | HeyGen Avatar 4 | Light denoise |
| AI influencer | Nanobanana Pro (consistent character) | ElevenLabs (cloned persona) | HeyGen Avatar 4 | Film grain + upscale |
| Budget/volume | Freepik | Qwen3-TTS (local) | InfiniteTalk | Minimal |

## Related Tools & Resources

### Internal References

- `tools/video/video-prompt-design.md` — Veo 3 Meta Framework (7-component prompting)
- `tools/video/higgsfield.md` — Higgsfield API integration
- `tools/video/heygen-skill.md` — HeyGen Avatar API (talking-head generation)
- `tools/video/muapi.md` — MuAPI (VEED lipsync, face swap, VFX)
- `tools/video/remotion.md` — Programmatic video editing
- `tools/voice/voice-models.md` — TTS model comparison (ElevenLabs, MiniMax, Qwen3-TTS)
- `tools/voice/qwen3-tts.md` — Qwen3-TTS setup and voice cloning
- `content/production/image.md` — Image generation (Nanobanana Pro, Midjourney, Freepik)
- `content/production/audio.md` — Voice pipeline, 4-Layer Audio Design
- `content/production/characters.md` — Character consistency (Facial Engineering, Character Bibles)
- `content/optimization.md` — A/B testing, seed bracketing automation
- `scripts/seed-bracket-helper.sh` — Seed bracketing CLI

### Helper Scripts

```bash
# Seed bracketing
seed-bracket-helper.sh generate --type product --prompt "Product rotating on white background"
seed-bracket-helper.sh score 4005 8 9 7 8 9 && seed-bracket-helper.sh report

# Unified video generation CLI (Sora 2, Veo 3.1, Nanobanana Pro)
video-gen-helper.sh generate sora "A cat reading a book" sora-2-pro 8 1280x720
video-gen-helper.sh generate veo "Cinematic mountain sunset" veo-3.1-generate-001 16:9
video-gen-helper.sh character /path/to/face.jpg
video-gen-helper.sh bracket "Product demo" https://example.com/product.jpg 4000 4010 dop-turbo
video-gen-helper.sh status sora vid_abc123 && video-gen-helper.sh download sora vid_abc123 ./output
video-gen-helper.sh models
```

### External Resources

- [Sora 2 Documentation](https://openai.com/sora)
- [Veo 3.1 Documentation](https://deepmind.google/technologies/veo/)
- [Higgsfield Platform](https://platform.higgsfield.ai)
- [HeyGen Platform](https://www.heygen.com/)
- [Topaz Video AI](https://www.topazlabs.com/topaz-video-ai)
