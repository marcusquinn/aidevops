---
description: "Video prompt design - AI video generation prompt engineering for Veo 3 and similar models using the 7-component meta prompt framework"
mode: subagent
upstream_url: https://github.com/snubroot/Veo-3-Meta-Framework
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Video Prompt Design

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate professional AI video prompts using structured meta prompt architecture
- **Primary Model**: Google Veo 3 (8s max, 1080p, 24fps, 16:9)
- **Framework**: 7-component format (Subject, Action, Scene, Style, Dialogue, Sounds, Technical)
- **Source**: [Veo 3 Meta Framework](https://github.com/snubroot/Veo-3-Meta-Framework)

**When to Use**: Read this when crafting prompts for AI video generation (Veo 3, Sora, Kling, etc.)

**Core Format** (all 7 components required for professional quality):

```text
Subject:   [Character with 15+ physical attributes]
Action:    [Movements, gestures, timing, micro-expressions]
Scene:     [Environment, props, lighting, weather, time of day]
Style:     [Camera shot, angle, movement, colour palette, depth of field]
Dialogue:  (Character Name): "Speech" (Tone: descriptor)
Sounds:    [Ambient, effects, music, environmental audio]
Technical: [Negative prompt - elements to exclude]
```

**Critical Techniques**:
- Camera positioning: Include `(thats where the camera is)` for spatial anchoring
- Dialogue format: Use colon syntax to prevent subtitle generation
- Audio: Always specify environment audio to prevent hallucinations
- Character consistency: Use identical descriptions across a series
- Duration: 12-15 words / 20-25 syllables for 8-second dialogue

<!-- AI-CONTEXT-END -->

## Detailed Guidance

### Character Development

Build characters with 15+ specific attributes for consistency across generations:

```text
[NAME], a [AGE] [ETHNICITY] [GENDER] with [HAIR_DETAILS], [EYE_COLOUR] eyes,
[FACIAL_FEATURES], [BUILD], wearing [CLOTHING], with [POSTURE],
[EMOTIONAL_STATE], [ACCESSORIES], [VOICE_CHARACTERISTICS]
```

**Required attributes**: Age, ethnicity, gender, hair (colour/style/length/texture), eyes (colour/shape), facial features, build (height/weight/type), clothing (style/colour/fit/material), posture, mannerisms, emotional baseline, voice, distinctive features, professional indicators, personality markers.

**Consistency rule**: Use the exact same character description wording across all prompts in a series.

### Camera Work

#### Shot Types

| Shot | Framing | Use Case |
|------|---------|----------|
| EWS | Full environment | Scale, context |
| WS | Full body | Character in environment |
| MS | Waist up | Conversation, standard |
| CU | Head/shoulders | Emotion, connection |
| ECU | Eyes/mouth | Intense emotion |

#### Movement Keywords

| Movement | Effect |
|----------|--------|
| `static shot` | Stability, authority |
| `dolly in/out` | Emotional intimacy control |
| `pan left/right` | Scene revelation |
| `tracking shot` | Subject following |
| `handheld` | Authenticity, energy |
| `crane shot` | Dramatic reveals |

#### Camera Positioning Syntax

Always include spatial context for the camera:

```text
"Close-up shot with camera positioned at counter level (thats where the camera is)
as the character demonstrates the product"
```

### Dialogue Design

**Colon format prevents subtitle generation**:

```text
CORRECT: The character looks at camera and says: 'This changes everything.'
WRONG:   The character says 'This changes everything.'
```

**8-second rule**: 12-15 words, 20-25 syllables maximum per generation.

Always specify tone and delivery:

```text
(Character Name): "Exact dialogue here"
(Tone: warm confidence with professional authority)
```

### Audio Engineering

**Always specify environment audio** to prevent hallucinations:

```text
Sounds: quiet office ambiance, keyboard typing, no audience sounds, professional atmosphere
```

**Domain-specific audio libraries**:

| Setting | Audio Elements |
|---------|---------------|
| Kitchen | Sizzling, chopping, boiling, utensils, ambiance |
| Office | Keyboard, fans, notifications, paper, professional |
| Workshop | Tools, machinery, metal, equipment, industrial |
| Outdoors | Wind, birds, traffic (distant), footsteps, natural |

### Negative Prompts (Technical Component)

**Universal quality negatives** (include in every prompt):

```text
subtitles, captions, watermark, text overlays, words on screen, logo, branding,
poor lighting, blurry footage, low resolution, artifacts, unwanted objects,
inconsistent character appearance, audio sync issues, amateur quality,
distorted hands, oversaturation, compression noise, camera shake
```

### Movement and Physics

**Movement quality modifiers** (add to Action component):

`natural movement`, `energetic movement`, `slow and deliberate`, `graceful`, `confident`, `fluid`

**Physics keywords** (for realistic results):

`realistic physics governing all actions`, `proper weight and balance`, `natural fluid dynamics`

### Selfie Video Formula

```text
A selfie video of [CHARACTER]. [He/She] holds the camera at arm's length.
[His/Her] [arm] is clearly visible in the frame. [He/She] occasionally
looks into the camera before [ACTION]. The image is slightly grainy,
looks very film-like. [He/She] says: "[DIALOGUE_8S_MAX]"
```

### Veo 3 Limitations

- Maximum 8 seconds per generation
- Complex multi-character scenes reduce consistency
- Rapid camera movements cause motion blur
- Background audio hallucinations without explicit specification
- Text/subtitles appear unless negated
- Hand/finger details need careful negative prompting
- 16:9 landscape is the primary supported aspect ratio

## Post-Processing Enhancement

After generating video with AI models (Veo, Sora, Runway), enhance output quality through upscaling, frame interpolation, and denoising using **REAL Video Enhancer**.

### When to Use Post-Processing

| Use Case | Enhancement | Result |
|----------|-------------|--------|
| **Social Media Delivery** | 720p → 1080p upscale + 24fps → 60fps interpolation | Smooth, high-quality social content |
| **Cinematic to Social** | 24fps → 48/60fps interpolation | Cinematic footage adapted for social platforms |
| **Low-Quality Source** | Denoise + upscale | Clean, professional output from compressed sources |
| **4K Delivery** | 1080p → 4K upscale | High-resolution output for premium platforms |
| **Artifact Removal** | H.264 decompression | Remove compression artifacts from AI-generated video |

### Quick Enhancement Workflow

```bash
# After generating with Veo/Sora/Runway
video-gen-helper.sh generate "your prompt" --model veo-3 --output raw.mp4

# Enhance for social media (1080p, 60fps)
real-video-enhancer-helper.sh enhance raw.mp4 final.mp4 \
  --scale 2 \
  --fps 60 \
  --denoise

# Verify output
ffprobe final.mp4  # Check resolution and frame rate
```

### Enhancement Options

**Upscaling** (improve resolution):

```bash
# 2x upscale (720p → 1080p or 1080p → 4K)
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 2

# 4x upscale (540p → 1080p or 720p → 4K)
real-video-enhancer-helper.sh upscale input.mp4 output.mp4 --scale 4
```

**Frame Interpolation** (increase frame rate):

```bash
# 24fps → 60fps (cinematic to social)
real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 --fps 60

# 24fps → 48fps (balanced smoothness)
real-video-enhancer-helper.sh interpolate input.mp4 output.mp4 --fps 48
```

**Denoising** (remove compression artifacts):

```bash
# Clean up noisy/compressed video
real-video-enhancer-helper.sh denoise input.mp4 output.mp4
```

**Full Pipeline** (upscale + interpolate + denoise):

```bash
# Maximum quality enhancement
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 \
  --scale 2 \
  --fps 60 \
  --denoise \
  --upscale-model realesrgan \
  --interpolate-model gmfss
```

### Integration with Video Production

See `content/production/video.md` for full production pipeline integration and `tools/video/real-video-enhancer.md` for detailed documentation.

**Typical workflow**:
1. **Prompt Design** (this guide) → Craft optimal prompts
2. **Generation** (`video-gen-helper.sh`) → Generate with Sora/Veo/Runway
3. **Enhancement** (`real-video-enhancer-helper.sh`) → Upscale, interpolate, denoise
4. **Post-Production** (color grading, audio mixing) → Final polish
5. **Distribution** (platform-specific encoding) → Deliver to platforms
