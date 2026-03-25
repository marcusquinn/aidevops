---
name: characters
description: Character design, facial engineering, character bibles, personas, and consistency across AI-generated content
mode: subagent
model: sonnet
tools:
  read: true
  write: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Character Production

AI-powered character design and consistency management for video content, brand personas, and multi-scene productions using facial engineering, character bibles, and cross-platform character reuse.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Create and maintain consistent characters across AI-generated content
- **Primary Techniques**: Facial engineering framework, character bibles, Sora 2 Cameos, Veo 3.1 Ingredients, Nanobanana character JSON
- **Key Principle**: "Model recency arbitrage" — always use latest-gen models, older outputs get recognized as AI faster
- **Related**: `content/production/image.md`, `content/production/video.md`, `tools/vision/image-generation.md`

**When to Use**: Creating brand mascots, recurring video characters, influencer personas, character-driven content series, or any production requiring visual consistency across multiple outputs.

<!-- AI-CONTEXT-END -->

## Facial Engineering Framework

Exhaustive facial analysis enables consistency across 100+ outputs. The more detailed your facial specification, the more consistent your character will be.

### Comprehensive Facial Analysis Prompt

```text
Analyze this face with exhaustive detail for AI character consistency:

BONE STRUCTURE:
- Face shape: [oval/round/square/heart/diamond/oblong]
- Jawline: [sharp/soft/angular/rounded/prominent/recessed]
- Cheekbones: [high/low/prominent/subtle/wide/narrow]
- Forehead: [broad/narrow/high/low/sloped/vertical]
- Chin: [pointed/rounded/square/cleft/prominent/recessed]
- Nose bridge: [high/low/straight/curved/wide/narrow]
- Brow ridge: [prominent/subtle/flat/protruding]

FACIAL FEATURES:
Eyes:
- Shape: [almond/round/hooded/upturned/downturned/monolid]
- Size: [large/medium/small] relative to face
- Spacing: [wide-set/close-set/average]
- Color: [specific hex code or detailed description]
- Iris pattern: [solid/flecked/ringed/central heterochromia]
- Eyelid: [single/double/hooded/deep-set]
- Lashes: [long/short/thick/sparse/curled/straight]
- Eyebrows: [thick/thin/arched/straight/angled/bushy/groomed]

Nose:
- Overall shape: [straight/aquiline/button/Roman/snub/hawk]
- Bridge: [high/low/wide/narrow/straight/curved]
- Tip: [pointed/rounded/bulbous/upturned/downturned]
- Nostrils: [wide/narrow/flared/pinched]
- Size: [large/medium/small] relative to face

Mouth:
- Lip fullness: [full/thin/medium/asymmetric]
- Upper lip: [full/thin/cupid's bow prominent/flat]
- Lower lip: [full/thin/protruding/recessed]
- Mouth width: [wide/narrow/proportional]
- Resting position: [closed/slightly open/corners up/corners down]
- Teeth: [visible/hidden/straight/gapped/prominent]
- Smile: [wide/subtle/asymmetric/dimples/no dimples]

Ears:
- Size: [large/medium/small]
- Position: [high-set/low-set/average]
- Protrusion: [flat/protruding/average]
- Lobe: [attached/detached/large/small]

SKIN:
- Tone: [specific hex codes for base, undertone, highlights]
- Undertone: [warm/cool/neutral/olive]
- Texture: [smooth/porous/rough/combination]
- Pores: [visible/invisible/enlarged in T-zone]
- Blemishes: [clear/freckles/moles/scars/birthmarks - specify locations]
- Age indicators: [fine lines/wrinkles/crow's feet/forehead lines/nasolabial folds]
- Skin condition: [dry/oily/combination/normal]
- Complexion: [even/uneven/ruddy/pale/tanned]

HAIR:
- Color: [specific hex codes for base, highlights, lowlights]
- Texture: [straight/wavy/curly/coily - specify curl pattern 1A-4C]
- Thickness: [fine/medium/coarse]
- Density: [thin/medium/thick]
- Length: [specific measurement or reference point]
- Style: [detailed description of cut and styling]
- Hairline: [straight/widow's peak/receding/high/low]
- Part: [center/side/no part]
- Facial hair (if applicable): [clean-shaven/stubble/beard/mustache - detailed description]

EXPRESSIONS & MICRO-EXPRESSIONS:
- Resting face: [neutral/slight smile/serious/contemplative]
- Common expressions: [list 3-5 characteristic expressions]
- Asymmetries: [any notable asymmetric features when expressing emotion]
- Eye crinkles: [present/absent when smiling]
- Forehead movement: [animated/static when expressing]
- Mouth movement: [wide range/subtle/asymmetric]

DISTINCTIVE FEATURES:
- Unique identifiers: [any scars, moles, birthmarks, asymmetries]
- Memorable characteristics: [what makes this face instantly recognizable]
- Aging markers: [specific to age range]
```

### Facial Engineering Output Format

Store the analysis as JSON for reuse across tools. Structure mirrors the analysis prompt:

```json
{
  "character_id": "unique_identifier",
  "face_structure": { "shape": "...", "jawline": "...", "cheekbones": "...", "forehead": "...", "chin": "...", "nose_bridge": "...", "brow_ridge": "..." },
  "eyes": { "shape": "...", "size": "...", "spacing": "...", "color": "#HEX", "iris_pattern": "...", "eyelid": "...", "lashes": "...", "eyebrows": "..." },
  "nose": { "shape": "...", "bridge": "...", "tip": "...", "nostrils": "...", "size": "..." },
  "mouth": { "lip_fullness": "...", "upper_lip": "...", "lower_lip": "...", "width": "...", "resting": "...", "teeth": "...", "smile": "..." },
  "skin": { "tone": "#HEX", "undertone": "...", "texture": "...", "blemishes": "...", "age_indicators": "...", "condition": "..." },
  "hair": { "color": "#HEX", "texture": "...", "thickness": "...", "density": "...", "length": "...", "style": "...", "hairline": "..." },
  "expressions": { "resting": "...", "common": ["..."], "asymmetries": "...", "eye_crinkles": "...", "forehead": "..." },
  "distinctive": ["..."]
}
```

## Character Bible Template

```markdown
# Character Bible: [Character Name]

## Identity
**Full Name**: | **Known As**: | **Age**: | **Gender**: | **Ethnicity**: | **Occupation**: | **Role**:

## Physical Appearance
### Face — [Paste facial engineering JSON or detailed description]
### Body — **Height**: | **Build**: | **Posture**: | **Distinctive physical traits**:
### Wardrobe — **Style**: | **Signature pieces**: | **Color palette**: (hex codes) | **Accessories**:

## Personality
- **Core Traits** (5): [Trait]: [How it manifests]
- **Values** (3): [Value]: [Why it matters]
- **Fears** (2): [Fear]: [How it affects behavior]
- **Motivations**: Primary + secondary
- **Arc**: Starting point → Growth areas → End goal

## Communication Style
**Vocabulary**: | **Sentence structure**: | **Pace**: | **Tone**: | **Verbal tics**: | **Catchphrases**:
**Non-Verbal**: Gestures, facial expressions, eye contact, personal space, energy level
**Content-Specific**: When teaching / storytelling / reacting / selling

## Expertise & Knowledge
**Areas** (3): [Domain]: [Depth] | **Gaps**: [Learning areas] | **Teaching Style**: [Approach]

## Backstory
**Origin**: | **Journey**: | **Current Situation**: | **Future Direction**:

## Relationships
**Audience**: How they view audience, expectations, boundaries
**Other Characters**: [Character]: [Relationship dynamic]

## Content & Brand
**Best suited for**: | **Avoid**: | **Typical Scenarios** (3):
**Brand Values Embodied** (3): | **Target Audience Resonance**: | **Differentiation**:

## Production Notes
Platform workflows: Sora 2 Cameos, Veo 3.1 Ingredients, Nanobanana JSON (see sections below).
**Voice** (if applicable): [Pitch, tone, accent, pace] | **ElevenLabs voice ID**: | **Emotional range**:

## Reference Assets
**Image**: facial engineering, full-body, wardrobe | **Video**: movement, expression | **Voice**: sample, emotional range
```

## Character Context Profile (Prompt-Ready)

Lightweight version for AI prompt context windows:

```text
CHARACTER: [Name]
VISUAL: Face: [2-3 sentences from facial engineering] | Body: [Height, build, posture] | Wardrobe: [Signature style] | Distinctive: [1-2 features]
PERSONALITY: Traits: [3-5 key traits] | Communication: [Style in 1-2 sentences] | Energy: [Vibe]
EXPERTISE: Knows: [Primary areas] | Teaching style: [Approach]
VOICE: Tone: [Overall] | Catchphrases: [1-3 phrases] | Tics: [Patterns]
CONTEXT: Role: [In this content] | Audience relationship: [How they relate] | Arc: [Current journey point]
```

## Sora 2 Cameos Workflow

```text
Style: clean, professional, studio lighting, neutral, high-quality, contemporary, commercial aesthetic
Shot: MS (medium shot), eye-level, static, centered, rule of thirds for headroom
Subject: [Paste character context profile VISUAL section]
Background: Pure white (#FFFFFF), seamless, no shadows, no texture
Lighting: Studio three-point (key 45° front-left, fill 45° front-right, rim from behind), soft diffused, 5500K
Actions:
  0.0s: Centered, neutral expression, looking at camera
  0.5s: Slight smile begins
  1.0s: Full genuine smile, eye contact
  1.5s: Subtle head tilt, friendly expression
  2.0s: Returns to neutral
  2.5s: Slight nod
Technical: 3s, 16:9, 4K, 30fps, Sony A7IV 50mm f/1.8, f/2.8, 1/200s, ISO 200
Negative: background elements, shadows on background, textured background, props, other people, motion blur, artifacts
```

### Cameo Library Structure

```text
characters/[character-name]/
├── cameos/          # neutral-front.mp4, smiling-front.mp4, talking-front.mp4, side-left/right.mp4, gesturing.mp4, walking.mp4
├── stills/          # portrait-front.png, portrait-side.png, full-body.png
├── character-bible.md
├── character-profile.txt
└── facial-engineering.json
```

## Veo 3.1 Ingredients Workflow

**ALWAYS use Ingredients-to-Video** (upload face as ingredient, reference in prompt).
**NEVER use Frame-to-Video** (produces grainy, yellow-tinted, inconsistent output).

### Reference Face Generation

Generate with Nanobanana Pro or Midjourney:

```json
{
  "subject": "[Paste facial engineering description]",
  "concept": "Professional character reference portrait",
  "composition": {"framing": "close-up", "angle": "eye-level", "focal_point": "eyes", "depth_of_field": "shallow"},
  "lighting": {"type": "studio", "direction": "three-point", "quality": "soft diffused", "color_temperature": "neutral (5500K)"},
  "style": {"aesthetic": "photorealistic", "texture": "smooth"},
  "technical": {"resolution": "4K", "aspect_ratio": "1:1"}
}
```

### Veo 3.1 Prompt Structure

```text
INGREDIENTS:
- Face: [character-name]-face

[Standard 7-component prompt — see tools/video/video-prompt-design.md]
Subject (use ingredient [character-name]-face) | Action | Context | Camera Movement | Composition | Lighting (complement ingredient face lighting) | Audio

Negative: different face, face swap, altered features, inconsistent appearance
```

## Nanobanana Character JSON Templates

Includes brand identity fields (color palette, lighting, camera) for cross-output consistency:

```json
{
  "template_name": "character-[name]-base",
  "template_version": "1.0",
  "character_id": "unique_identifier",
  "subject_base": "[Facial engineering description - 2-3 sentences]",
  "subject_variables": {
    "expression": "[neutral/smiling/serious/surprised]",
    "pose": "[standing/sitting/walking/gesturing]",
    "clothing": "[Specific outfit from character bible]",
    "context": "[Environment or activity]"
  },
  "composition": {"framing": "[variable]", "angle": "eye-level", "rule_of_thirds": true, "focal_point": "eyes", "depth_of_field": "shallow"},
  "lighting": {"type": "[brand consistent]", "direction": "[brand consistent]", "quality": "[brand consistent]", "color_temperature": "[brand consistent]"},
  "color": {"palette": ["#HEX1", "#HEX2", "#HEX3"], "dominant": "[brand primary]", "accent": "[brand accent]"},
  "style": {"aesthetic": "[brand aesthetic]", "texture": "[brand texture]", "post_processing": "[brand post-processing]"},
  "technical": {"camera": "[consistent model]", "lens": "[consistent lens]", "settings": "[consistent settings]", "resolution": "4K", "aspect_ratio": "[variable]"},
  "negative": "different face, altered features, inconsistent appearance, blurry, low quality, distorted, watermark"
}
```

Template variants: `templates/characters/[name]/` — `base.json`, `thumbnail-excited.json`, `thumbnail-serious.json`, `social-casual.json`, `professional-headshot.json`, `action-teaching.json`

## Brand Identity Template

Define once, reference from all character templates to ensure visual constants (lighting direction, color temperature, mood, post-processing LUT, camera model/lens/settings):

```json
{
  "brand_name": "[Your Brand]",
  "visual_identity": {
    "color_palette": {"primary": "#HEX", "secondary": "#HEX", "accent": "#HEX"},
    "lighting": {"type": "natural", "quality": "soft diffused", "color_temperature": "warm (4500K)", "mood": "bright and airy"},
    "post_processing": {"color_grade": "Warm with slight orange/teal split", "film_grain": "Subtle (10%)", "contrast": "Medium (1.2x)", "saturation": "Slightly boosted (1.1x)"},
    "camera_aesthetic": {"camera": "Sony A7IV", "lens": "50mm f/1.8", "settings": "f/2.8, 1/200s, ISO 400"}
  }
}
```

## Model Recency Arbitrage

**Always use latest-generation AI models.** Audience AI-detection timeline: 0-3 months (cutting-edge) → 3-6 months (patterns recognizable) → 6-12 months ("AI look" obvious) → 12+ months (dated).

**Current generation (2026)**: Sora 2 Pro, Veo 3.1, Nanobanana Pro, FLUX.1 Pro, Midjourney v7

**On model upgrade**: Test character consistency → update prompts → regenerate reference images, Cameos, Ingredients, and JSON templates → update brand post-processing → document quirks → archive old outputs.

## Character Consistency Verification

### Checklist

- **Facial Features**: face shape, eye shape/color/spacing, nose, mouth/lips, skin tone/texture, hair, distinctive features
- **Body & Wardrobe**: body type/build, height proportions, wardrobe, colors, accessories, posture
- **Expression & Behavior**: expressions match personality, body language, gestures, eye contact
- **Brand Alignment**: lighting, color grading, post-processing, overall aesthetic

### Cross-Content Consistency

| Context | Facial features | Wardrobe | Lighting | Camera |
|---------|----------------|----------|----------|--------|
| Same scene/series | Exact match | Same | Same | Same |
| Different scenes/episodes | Consistent | Variations within style | Varies by location, maintain brand mood | Consistent |
| Different platforms | Always consistent | Adapted to platform norms | Adapted to platform norms | Format adapted |

### Common Issues & Fixes

| Issue | Fix |
|-------|-----|
| Face changes between generations | More detailed facial engineering; hex codes; use Veo 3.1 Ingredients |
| Wardrobe inconsistency | Hex codes; list exact items; use Nanobanana JSON; composite onto scenes |
| Expression doesn't match personality | Include personality in prompt; specify exact emotion; reference bible |
| Lighting/style inconsistency | Brand identity template; same lighting params; consistent LUT; batch generate |

## Multi-Character Management

**Differentiation Matrix** (example):

| Character | Face Shape | Eye Color | Hair | Wardrobe | Personality | Voice |
|-----------|------------|-----------|------|----------|-------------|-------|
| Alex | Oval | Brown | Black | Minimalist | Analytical | Calm |
| Sarah | Heart | Green | Blonde | Colorful | Energetic | Upbeat |
| Marcus | Square | Blue | Brown | Professional | Authoritative | Deep |

Rules: distinct visual markers per character; consistent relationship dynamics; complementary (not overlapping) expertise; same brand identity across all.

## Character Evolution

**Can change**: wardrobe, hair style, expressions, expertise, confidence
**Must stay consistent**: facial bone structure, eye color/shape, skin tone, core personality, voice, distinctive features

Track changes in a version log: Version | Changes | Reason | Audience Response.

## Tools & Resources

**Image**: Nanobanana Pro (JSON prompts), Midjourney (objects/environments), Freepik (character scenes), Seedream 4 (4K refinement), Ideogram (face swap, text)
**Video**: Sora 2 Pro (UGC-style), Veo 3.1 (cinematic, character-consistent), Higgsfield (multi-model)
**Voice**: ElevenLabs (cloning/transformation), CapCut (AI voice cleanup — use BEFORE ElevenLabs)

**Related docs**: `content/production/image.md`, `content/production/video.md`, `content/production/audio.md`, `tools/vision/image-generation.md`, `tools/video/video-prompt-design.md`

## Workflow Summary

**New Character**: Define purpose → facial engineering → character bible → reference assets → JSON templates → test consistency → document in library

**Existing Character**: Reference bible → load template (Nanobanana/Sora/Veo) → adapt → generate → verify consistency → publish → document evolution

**Maintain Consistency**: Regular audits → update bible on changes → upgrade AI models → regenerate assets → monitor feedback → iterate

**Content Pipeline**: Research (`content/research.md`) → Story (`content/story.md`) → Production (writing, image, video, audio) → Distribution (`content/distribution/`) → Optimization (`content/optimization.md`)

---

**Last Updated**: 2026-03-25 | **Version**: 1.1 | **Related Tasks**: t199.7
