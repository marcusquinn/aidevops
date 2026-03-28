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

AI-powered character design and consistency management using facial engineering, character bibles, and cross-platform character reuse.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary Techniques**: Facial engineering framework, character bibles, Sora 2 Cameos, Veo 3.1 Ingredients, Nanobanana character JSON
- **Key Principle**: "Model recency arbitrage" — always use latest-gen models; older outputs get recognized as AI faster
- **When to Use**: Brand mascots, recurring video characters, influencer personas, any production requiring visual consistency across multiple outputs
- **Related**: `content/production-image.md`, `content/production-video.md`, `tools/vision/image-generation.md`

<!-- AI-CONTEXT-END -->

## Facial Engineering Framework

Exhaustive facial analysis enables consistency across 100+ outputs. More detail = more consistency.

### Comprehensive Facial Analysis Prompt

```text
Analyze this face with exhaustive detail for AI character consistency:

BONE STRUCTURE: face shape [oval/round/square/heart/diamond/oblong] | jawline [sharp/soft/angular/rounded/prominent/recessed] | cheekbones [high/low/prominent/subtle] | forehead [broad/narrow/high/low/sloped] | chin [pointed/rounded/square/cleft/prominent/recessed] | nose bridge [high/low/straight/curved/wide/narrow] | brow ridge [prominent/subtle/flat/protruding]

EYES: shape [almond/round/hooded/upturned/downturned/monolid] | size [large/medium/small] | spacing [wide/close/average] | color [hex] | iris pattern | eyelid [single/double/hooded/deep-set] | lashes [long/short/thick/sparse/curled/straight] | eyebrows [thick/thin/arched/straight/angled/bushy/groomed]

NOSE: shape [straight/aquiline/button/Roman/snub/hawk] | bridge [high/low/wide/narrow] | tip [pointed/rounded/bulbous/upturned/downturned] | nostrils [wide/narrow/flared/pinched] | size relative to face

MOUTH: lip fullness [full/thin/medium/asymmetric] | upper lip [full/thin/cupid's bow/flat] | lower lip [full/thin/protruding/recessed] | width [wide/narrow/proportional] | resting [closed/slightly open/corners up/down] | teeth [visible/hidden/straight/gapped] | smile [wide/subtle/asymmetric/dimples]

EARS: size [large/medium/small] | position [high/low/average] | protrusion [flat/protruding/average] | lobe [attached/detached/large/small]

SKIN: tone [hex codes for base, undertone, highlights] | undertone [warm/cool/neutral/olive] | texture [smooth/porous/rough/combination] | blemishes [clear/freckles/moles/scars/birthmarks — locations] | age indicators [fine lines/wrinkles/crow's feet/nasolabial folds]

HAIR: color [hex codes for base, highlights, lowlights] | texture [straight/wavy/curly/coily — curl pattern 1A-4C] | thickness [fine/medium/coarse] | length [measurement] | style [cut and styling] | hairline [straight/widow's peak/receding/high/low] | part [center/side/none] | facial hair [clean-shaven/stubble/beard/mustache]

EXPRESSIONS: resting [neutral/slight smile/serious/contemplative] | common expressions [3-5 characteristic] | asymmetries | eye crinkles when smiling | forehead/mouth movement range

DISTINCTIVE: unique identifiers [scars, moles, birthmarks, asymmetries] | memorable characteristics [what makes this face instantly recognizable]
```

Store analysis as JSON: `character_id`, `face_structure` (7 fields), `eyes` (8), `nose` (5), `mouth` (7), `skin` (5), `hair` (6), `expressions` (4), `distinctive` (array). Hex codes for all colors. Save to `characters/[name]/facial-engineering.json`.

## Character Bible Template

```markdown
# Character Bible: [Character Name]

## Identity
**Full Name**: | **Known As**: | **Age**: | **Gender**: | **Ethnicity**: | **Occupation**: | **Role**:

## Physical Appearance
**Face**: [Paste facial engineering JSON] | **Body**: Height | Build | Posture | Distinctive traits
**Wardrobe**: Style | Signature pieces | Color palette (hex) | Accessories

## Personality
**Core Traits** (5): [Trait]: [How it manifests] | **Values** (3): [Value]: [Why it matters]
**Fears** (2): [Fear]: [How it affects behavior] | **Motivations**: Primary + secondary
**Arc**: Starting point → Growth areas → End goal

## Communication Style
**Verbal**: Vocabulary | Sentence structure | Pace | Tone | Verbal tics | Catchphrases
**Non-Verbal**: Gestures, facial expressions, eye contact, personal space, energy level
**Content-Specific**: When teaching / storytelling / reacting / selling

## Expertise & Knowledge
**Areas** (3): [Domain]: [Depth] | **Gaps**: [Learning areas] | **Teaching Style**: [Approach]

## Backstory & Relationships
**Origin**: | **Journey**: | **Current Situation**: | **Future Direction**:
**Audience**: How they view audience, expectations, boundaries
**Other Characters**: [Character]: [Relationship dynamic]

## Content & Brand
**Best suited for**: | **Avoid**: | **Typical Scenarios** (3):
**Brand Values** (3): | **Target Audience Resonance**: | **Differentiation**:

## Production Notes
**Workflows**: Sora 2 Cameos, Veo 3.1 Ingredients, Nanobanana JSON (see sections below)
**Voice**: Pitch | Tone | Accent | Pace | ElevenLabs voice ID | Emotional range
**Assets**: Image (facial engineering, full-body, wardrobe) | Video (movement, expression) | Voice (sample)
```

## Character Context Profile (Prompt-Ready)

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
Actions: 0.0s neutral → 0.5s smile begins → 1.0s full smile/eye contact → 1.5s head tilt → 2.0s neutral → 2.5s nod
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

**ALWAYS use Ingredients-to-Video** (upload face as ingredient). **NEVER use Frame-to-Video** (grainy, yellow-tinted, inconsistent).

Generate reference face with Nanobanana Pro or Midjourney: photorealistic, close-up, eye-level, studio three-point lighting, 4K, 1:1.

### Veo 3.1 Prompt Structure

```text
INGREDIENTS:
- Face: [character-name]-face

[Standard 7-component prompt — see tools/video/video-prompt-design.md]
Subject (use ingredient [character-name]-face) | Action | Context | Camera Movement | Composition | Lighting (complement ingredient face lighting) | Audio

Negative: different face, face swap, altered features, inconsistent appearance
```

## Nanobanana Character JSON Templates

Brand identity fields (color palette, lighting, camera) ensure cross-output consistency:

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

Define once, reference from all character templates. Ensures visual constants across all outputs:

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

**Always use latest-generation AI models.** Detection timeline: 0-3 months (cutting-edge) → 3-6 months (patterns recognizable) → 6-12 months ("AI look" obvious) → 12+ months (dated).

**Current generation (2026)**: Sora 2 Pro, Veo 3.1, Nanobanana Pro, FLUX.1 Pro, Midjourney v7

**On model upgrade**: Test consistency → update prompts → regenerate reference images/Cameos/Ingredients/JSON templates → update brand post-processing → document quirks → archive old outputs.

## Character Consistency Verification

**Checklist**: facial features (shape, eyes, nose, mouth, skin, hair, distinctive) | body & wardrobe (build, height, style, colors, accessories, posture) | expression & behavior | brand alignment (lighting, color grading, post-processing)

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

**Differentiation Matrix**:

| Character | Face Shape | Eye Color | Hair | Wardrobe | Personality | Voice |
|-----------|------------|-----------|------|----------|-------------|-------|
| Alex | Oval | Brown | Black | Minimalist | Analytical | Calm |
| Sarah | Heart | Green | Blonde | Colorful | Energetic | Upbeat |
| Marcus | Square | Blue | Brown | Professional | Authoritative | Deep |

Rules: distinct visual markers per character; consistent relationship dynamics; complementary (not overlapping) expertise; same brand identity across all.

## Character Evolution

**Can change**: wardrobe, hair style, expressions, expertise, confidence
**Must stay consistent**: facial bone structure, eye color/shape, skin tone, core personality, voice, distinctive features
**Version log**: Version | Changes | Reason | Audience Response

## Tools & Resources

**Image**: Nanobanana Pro (JSON prompts), Midjourney (objects/environments), Freepik (character scenes), Seedream 4 (4K refinement), Ideogram (face swap, text)
**Video**: Sora 2 Pro (UGC-style), Veo 3.1 (cinematic, character-consistent), Higgsfield (multi-model)
**Voice**: ElevenLabs (cloning/transformation), CapCut (AI voice cleanup — use BEFORE ElevenLabs)

**Related docs**: `content/production-image.md`, `content/production-video.md`, `content/production-audio.md`, `tools/vision/image-generation.md`, `tools/video/video-prompt-design.md`

## Workflow Summary

**New Character**: Define purpose → facial engineering → character bible → reference assets → JSON templates → test consistency → document in library

**Existing Character**: Reference bible → load template (Nanobanana/Sora/Veo) → adapt → generate → verify consistency → publish → document evolution

**Maintain Consistency**: Regular audits → update bible on changes → upgrade AI models → regenerate assets → monitor feedback → iterate

**Content Pipeline**: Research (`content/research.md`) → Story (`content/story.md`) → Production (writing, image, video, audio) → Distribution (`content/distribution-*.md`) → Optimization (`content/optimization.md`)

---

**Last Updated**: 2026-03-28 | **Version**: 1.2 | **Related Tasks**: t199.7
