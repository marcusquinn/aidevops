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

```json
{
  "character_id": "unique_identifier",
  "face_structure": {
    "shape": "oval",
    "jawline": "sharp and angular",
    "cheekbones": "high and prominent",
    "forehead": "broad and high",
    "chin": "pointed with slight cleft",
    "nose_bridge": "high and straight",
    "brow_ridge": "subtle"
  },
  "eyes": {
    "shape": "almond",
    "size": "large",
    "spacing": "wide-set",
    "color": "#4A7C59",
    "iris_pattern": "central heterochromia with gold flecks",
    "eyelid": "double",
    "lashes": "long and curled",
    "eyebrows": "thick, slightly arched, natural"
  },
  "nose": {
    "shape": "straight",
    "bridge": "high and narrow",
    "tip": "slightly rounded",
    "nostrils": "narrow",
    "size": "proportional"
  },
  "mouth": {
    "lip_fullness": "medium",
    "upper_lip": "defined cupid's bow",
    "lower_lip": "slightly fuller than upper",
    "width": "proportional",
    "resting": "corners slightly up",
    "teeth": "straight, visible when smiling",
    "smile": "wide with dimples on both cheeks"
  },
  "skin": {
    "tone": "#F5D7C3",
    "undertone": "warm",
    "texture": "smooth with visible pores in T-zone",
    "blemishes": "light freckles across nose and cheeks",
    "age_indicators": "fine lines at outer eye corners",
    "condition": "combination"
  },
  "hair": {
    "color": "#3D2817",
    "texture": "wavy (2B curl pattern)",
    "thickness": "medium",
    "density": "thick",
    "length": "shoulder-length",
    "style": "loose waves with side part",
    "hairline": "straight with slight widow's peak"
  },
  "expressions": {
    "resting": "slight smile, approachable",
    "common": ["genuine smile with eye crinkles", "thoughtful with slight head tilt", "surprised with raised eyebrows"],
    "asymmetries": "left eyebrow raises slightly higher",
    "eye_crinkles": "prominent when smiling",
    "forehead": "animated, expressive"
  },
  "distinctive": [
    "Dimples on both cheeks when smiling",
    "Small mole above right eyebrow",
    "Asymmetric eyebrow movement",
    "Gold flecks in green eyes"
  ]
}
```

## Character Bible Template

```markdown
# Character Bible: [Character Name]

## Identity
**Full Name**: | **Known As**: | **Age**: | **Gender**: | **Ethnicity**: | **Occupation**: | **Role**:

## Physical Appearance

### Face
[Paste facial engineering JSON or detailed description]

### Body
- **Height**: | **Build**: | **Posture**: | **Distinctive physical traits**:

### Wardrobe
**Style**: | **Signature pieces**: | **Color palette**: (hex codes) | **Accessories**: | **Seasonal variations**:

## Personality

### Core Traits (5): [Trait]: [How it manifests]
### Values (3): [Value]: [Why it matters]
### Fears/Vulnerabilities (2): [Fear]: [How it affects behavior]
### Motivations: Primary + secondary
### Character Arc: Starting point → Growth areas → End goal

## Communication Style

**Vocabulary level**: | **Sentence structure**: | **Pace**: | **Tone**: | **Verbal tics**: | **Catchphrases**:

**Non-Verbal**: Gestures, facial expressions, eye contact, personal space, energy level

**Content-Specific**: When teaching / storytelling / reacting / selling

## Expertise & Knowledge

**Areas of Expertise** (3): [Domain]: [Depth]
**Knowledge Gaps**: [What they don't know / are learning]
**Teaching Style**: [How they break down complex topics]

## Backstory

**Origin**: | **Journey**: | **Current Situation**: | **Future Direction**:

## Relationships

**Audience Relationship**: How they view audience, expectations, boundaries
**Other Characters**: [Character]: [Relationship dynamic]

## Content Integration

**Best suited for**: | **Avoid**: | **Typical Scenarios** (3): | **Conflict & Challenge**:

## Brand Alignment

**Brand Values Embodied** (3): | **Target Audience Resonance**: | **Differentiation**:

## Production Notes

**Sora 2 Cameos**: Generate on white background, save as reusable asset, composite into scenes
**Veo 3.1 Ingredients**: Upload facial engineering reference, use for cross-scene consistency
**Nanobanana Character JSON**: Save facial engineering JSON as template, reuse with different poses

### Visual Consistency Checklist
- [ ] Facial features match engineering spec
- [ ] Wardrobe aligns with character bible
- [ ] Expressions match personality traits
- [ ] Body language reflects character energy
- [ ] Color palette consistent across outputs
- [ ] Lighting style matches brand identity
- [ ] Post-processing consistent (film grain, color grade)

### Voice Consistency (if applicable)
**Voice characteristics**: [Pitch, tone, accent, pace] | **ElevenLabs voice ID**: | **Emotional range**:

## Evolution & Updates

**Last updated**: | **Recent changes**: | **Planned evolution**:

## Reference Assets

**Image references**: facial engineering, full-body, wardrobe
**Video references**: movement, expression
**Voice references**: voice sample, emotional range demo
```

## Character Context Profile (Prompt-Ready)

Lightweight version optimized for AI prompt context:

```text
CHARACTER: [Name]

VISUAL:
Face: [2-3 sentence summary from facial engineering]
Body: [Height, build, posture]
Wardrobe: [Signature style and colors]
Distinctive: [1-2 most memorable features]

PERSONALITY:
Core traits: [3-5 key traits]
Communication: [Speaking style in 1-2 sentences]
Energy: [Overall vibe/energy level]

EXPERTISE:
Knows: [Primary areas of expertise]
Teaching style: [How they explain things]

VOICE:
Tone: [Overall tone]
Catchphrases: [1-3 signature phrases]
Verbal tics: [Notable speech patterns]

CONTEXT:
Role: [Their role in this content]
Relationship to audience: [How they relate to viewers]
Current arc: [Where they are in their journey]
```

## Sora 2 Cameos Workflow

### Cameo Generation Prompt

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

### Cameo Library Organization

```text
characters/[character-name]/
├── cameos/
│   ├── neutral-front.mp4
│   ├── smiling-front.mp4
│   ├── talking-front.mp4
│   ├── neutral-side-left.mp4
│   ├── neutral-side-right.mp4
│   ├── gesturing-front.mp4
│   └── walking-front.mp4
├── stills/
│   ├── portrait-front.png
│   ├── portrait-side.png
│   └── full-body.png
├── character-bible.md
├── character-profile.txt
└── facial-engineering.json
```

## Veo 3.1 Ingredients Workflow

**ALWAYS use Ingredients-to-Video** (upload face as ingredient, reference in prompt, maintain lighting consistency).
**NEVER use Frame-to-Video** (produces grainy, yellow-tinted, inconsistent output).

### Reference Face Generation (Nanobanana Pro or Midjourney)

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

[Standard 7-component prompt]
- Subject: Use ingredient [character-name]-face
- Action: [Character actions]
- Context: [Scene environment]
- Camera Movement: [Camera work]
- Composition: [Shot composition]
- Lighting: [Must complement ingredient face lighting]
- Audio: [Audio design]

Negative: different face, face swap, altered features, inconsistent appearance
```

## Nanobanana Character JSON Templates

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
  "color": {"palette": ["[brand color 1]", "[brand color 2]", "[brand color 3]"], "dominant": "[brand primary]", "accent": "[brand accent]"},
  "style": {"aesthetic": "[brand aesthetic]", "texture": "[brand texture]", "post_processing": "[brand post-processing]"},
  "technical": {"camera": "[consistent model]", "lens": "[consistent lens]", "settings": "[consistent settings]", "resolution": "4K", "aspect_ratio": "[variable]"},
  "negative": "different face, altered features, inconsistent appearance, blurry, low quality, distorted, watermark"
}
```

Template library: `templates/characters/[name]/base.json`, `thumbnail-excited.json`, `thumbnail-serious.json`, `social-casual.json`, `professional-headshot.json`, `action-teaching.json`

## Brand Identity Consistency

```json
{
  "brand_name": "[Your Brand]",
  "visual_identity": {
    "color_palette": {"primary": "#HEX", "secondary": "#HEX", "accent": "#HEX"},
    "lighting": {"type": "natural", "quality": "soft diffused", "color_temperature": "warm (4500K)", "mood": "bright and airy"},
    "post_processing": {"color_grade": "Warm and inviting with slight orange/teal split", "film_grain": "Subtle (10%)", "contrast": "Medium (1.2x)", "saturation": "Slightly boosted (1.1x)"},
    "camera_aesthetic": {"camera": "Sony A7IV", "lens": "50mm f/1.8", "settings": "f/2.8, 1/200s, ISO 400"}
  }
}
```

**Visual constants**: consistent lighting direction, color temperature, mood, post-processing LUT, camera model/lens/settings across all character content.

## Model Recency Arbitrage

**Always use latest-generation AI models.** Audience AI-detection timeline:
- Months 0-3: Cutting-edge, audiences impressed
- Months 3-6: Patterns recognizable, still acceptable
- Months 6-12: "AI look" becomes obvious
- Months 12+: Outputs look dated

**Current generation (2026)**: Sora 2 Pro, Veo 3.1, Nanobanana Pro, FLUX.1 Pro, Midjourney v7

### Model Update Checklist

- [ ] Test character consistency with new model
- [ ] Update facial engineering prompts if needed
- [ ] Regenerate character reference images and Sora 2 Cameos
- [ ] Update Veo 3.1 Ingredients and Nanobanana JSON templates
- [ ] Regenerate thumbnail templates
- [ ] Update brand identity post-processing to match new model output
- [ ] Document new model quirks and best practices
- [ ] Archive old model outputs for comparison

## Character Consistency Verification

### Visual Consistency Checklist

**Facial Features**: face shape, eye shape/color/spacing, nose, mouth/lips, skin tone/texture, hair, distinctive features

**Body & Wardrobe**: body type/build, height proportions, wardrobe, colors, accessories, posture

**Expression & Behavior**: expressions match personality, body language, gestures, eye contact, micro-expressions

**Brand Alignment**: lighting, color grading, post-processing, overall aesthetic

### Cross-Content Consistency

| Context | Facial features | Wardrobe | Lighting | Camera |
|---------|----------------|----------|----------|--------|
| Same scene/series | Exact match | Same | Same | Same |
| Different scenes/episodes | Consistent | Variations within style | Varies by location, maintain brand mood | Consistent |
| Different platforms | Always consistent | Adapted to platform norms | Adapted to platform norms | Format adapted |

## Common Consistency Issues & Solutions

| Issue | Symptoms | Solutions |
|-------|----------|-----------|
| Face changes between generations | Different eye color/shape, nose, skin tone, hair | More detailed facial engineering; hex codes for colors; use Veo 3.1 Ingredients |
| Wardrobe inconsistency | Different clothing colors, missing accessories | Hex codes for wardrobe; list exact items; use Nanobanana JSON; composite onto scenes |
| Expression doesn't match personality | Generic or wrong expressions | Include personality traits in prompt; specify exact emotion; reference character bible |
| Lighting/style inconsistency | Different mood, color grading, post-processing | Brand identity template with exact specs; same lighting params; consistent LUT; batch generate |

## Integration with Content Pipeline

1. **Research** (`content/research.md`): Identify audience personas, research competitor characters
2. **Story** (`content/story.md`): Develop character arc, plan character-driven narratives
3. **Production**:
   - Writing (`content/production/writing.md`): Dialogue in character voice
   - Image (`content/production/image.md`): Portraits and thumbnails
   - Video (`content/production/video.md`): Character video content
   - Audio (`content/production/audio.md`): Voice cloning
4. **Distribution** (`content/distribution/`): Adapt for each platform, maintain consistency
5. **Optimization** (`content/optimization.md`): A/B test character variations, iterate on performance data

## Multi-Character Management

**Character Differentiation Matrix**:

| Character | Face Shape | Eye Color | Hair | Wardrobe | Personality | Voice |
|-----------|------------|-----------|------|----------|-------------|-------|
| Alex | Oval | Brown | Black | Minimalist | Analytical | Calm |
| Sarah | Heart | Green | Blonde | Colorful | Energetic | Upbeat |
| Marcus | Square | Blue | Brown | Professional | Authoritative | Deep |

Rules: distinct visual markers per character; consistent relationship dynamics; complementary (not overlapping) expertise; same brand identity across all.

## Character Evolution

**What can change**: wardrobe, hair style, expressions, expertise, confidence
**What must stay consistent**: facial bone structure, eye color/shape, skin tone, core personality, voice, distinctive features

```markdown
# Character Evolution Log: [Name]

## Version 1.0 (Launch - Month 3)
- Initial design: Wardrobe / Personality / Expertise

## Version 1.1 (Month 4-6)
**Changes**: [What changed] | **Reason**: [Why] | **Audience Response**: [How they reacted]
```

## Tools & Resources

**Image Generation**: Nanobanana Pro (JSON prompts), Midjourney (objects/environments), Freepik (character scenes), Seedream 4 (4K refinement), Ideogram (face swap, text)

**Video Generation**: Sora 2 Pro (UGC-style), Veo 3.1 (cinematic, character-consistent), Higgsfield (multi-model platform)

**Voice Cloning**: ElevenLabs (cloning/transformation), CapCut (AI voice cleanup — use BEFORE ElevenLabs)

```bash
# Character asset management (if implemented)
character-helper.sh create [name]           # Create new character bible
character-helper.sh generate [name] [type]  # Generate character asset
character-helper.sh verify [name]           # Check consistency across assets
character-helper.sh library                 # List all characters
```

**Related docs**: `content/production/image.md`, `content/production/video.md`, `content/production/audio.md`, `tools/vision/image-generation.md`, `tools/video/video-prompt-design.md`, `content/optimization.md`

## Workflow Summary

**Creating a New Character**:
1. Define purpose and audience fit → 2. Complete facial engineering → 3. Build character bible → 4. Generate reference assets → 5. Create JSON templates → 6. Test consistency → 7. Document in library

**Using an Existing Character**:
1. Reference character bible → 2. Load template (Nanobanana JSON / Sora Cameo / Veo Ingredient) → 3. Adapt for use case → 4. Generate → 5. Verify consistency → 6. Publish → 7. Document evolution

**Maintaining Consistency**:
1. Regular consistency audits → 2. Update bible on intentional changes → 3. Upgrade to latest AI models → 4. Regenerate reference assets → 5. Monitor audience feedback → 6. Iterate on performance data

---

**Last Updated**: 2026-02-10 | **Version**: 1.0 | **Related Tasks**: t199.7
