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

**Domain-specific additions**:
- Corporate: `no casual attire, no distracting backgrounds, no poor posture`
- Educational: `no overly dramatic presentation, no artificial staging`
- Social media: `no outdated trends, no poor mobile optimisation`

### Physics-Aware Prompting

Include physics keywords for realistic movement:

```text
"realistic physics governing all actions"
"natural fluid dynamics"
"authentic momentum conservation"
"proper weight and balance"
```

**Movement quality modifiers**: `natural movement`, `energetic movement`, `slow and deliberate`, `graceful`, `confident`, `fluid`.

### Selfie Video Formula

```text
A selfie video of [CHARACTER]. [He/She] holds the camera at arm's length.
[His/Her] [arm] is clearly visible in the frame. [He/She] occasionally
looks into the camera before [ACTION]. The image is slightly grainy,
looks very film-like. [He/She] says: "[DIALOGUE_8S_MAX]"
```

### Quality Tiers

| Tier | Components | Automation |
|------|-----------|------------|
| Advanced | All 7 + physics + meta prompt | Full |
| Professional | 6-7 with detail | Partial |
| Intermediate | 4-6 basic | Minimal |
| Basic | 1-3 (poor results) | None |

### Domain Templates

**Corporate**: Executive presence, brand compliance, three-point lighting, authoritative framing, business formal attire, corporate environments.

**Educational**: Visual-auditory sync, cognitive load management, clear progression, multi-sensory engagement, retention-focused design.

**Social media**: Hook within 2 seconds, emotional engagement, platform-specific formatting, viral mechanics, demographic targeting.

### Meta Prompt Generation

When generating meta prompts (prompts that generate prompts), follow this cognitive architecture:

1. **Identity layer**: Define role and expertise
2. **Knowledge layer**: Technical specs and best practices
3. **Analysis layer**: Parse requirements and optimise
4. **Generation layer**: Apply 7-component format
5. **Quality layer**: Validate against checklist
6. **Output layer**: Structured response with alternatives

### Success Metrics

| Metric | Target |
|--------|--------|
| Generation success rate | >95% |
| Character consistency | >98% |
| Audio-visual sync | >97% |
| Brand compliance | 100% |

### Veo 3 Limitations

- Maximum 8 seconds per generation
- Complex multi-character scenes reduce consistency
- Rapid camera movements cause motion blur
- Background audio hallucinations without explicit specification
- Text/subtitles appear unless negated
- Hand/finger details need careful negative prompting
- 16:9 landscape is the primary supported aspect ratio
