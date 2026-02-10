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
- **Related**: `content/production/image.md` (character portraits), `content/production/video.md` (character video), `tools/vision/image-generation.md` (model comparison)

**When to Use**: Creating brand mascots, recurring video characters, influencer personas, character-driven content series, or any production requiring visual consistency across multiple outputs.

<!-- AI-CONTEXT-END -->

## Facial Engineering Framework

Exhaustive facial analysis enables consistency across 100+ outputs. The more detailed your facial specification, the more consistent your character will be across different AI models and generations.

### Comprehensive Facial Analysis Prompt

Use this prompt to analyze existing faces (from reference images) or to specify new character faces:

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

After analysis, structure the output as a reusable character specification:

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

A character bible is the single source of truth for maintaining consistency across all content featuring the character. This goes beyond facial features to include personality, voice, wardrobe, and behavior.

### Complete Character Bible Structure

```markdown
# Character Bible: [Character Name]

## Identity

**Full Name**: [Legal/full name]
**Known As**: [Nickname, stage name, or common name]
**Age**: [Specific age or range]
**Gender**: [Gender identity]
**Ethnicity**: [Cultural/ethnic background]
**Occupation**: [What they do]
**Role**: [Their role in your content - host, expert, mascot, etc.]

## Physical Appearance

### Face
[Paste facial engineering JSON or detailed description]

### Body
- **Height**: [Specific measurement]
- **Build**: [Slim/athletic/average/muscular/curvy/etc.]
- **Posture**: [Upright/slouched/confident/relaxed]
- **Distinctive physical traits**: [Tattoos, scars, unique features]

### Wardrobe

**Style**: [Overall aesthetic - casual, professional, streetwear, etc.]

**Signature pieces**:
- [Item 1 with specific details]
- [Item 2 with specific details]
- [Item 3 with specific details]

**Color palette**: [Hex codes for primary wardrobe colors]
- Primary: #HEX
- Secondary: #HEX
- Accent: #HEX

**Accessories**: [Glasses, jewelry, watches, hats - be specific]

**Seasonal variations**: [How wardrobe changes across seasons/contexts]

## Personality

### Core Traits
1. [Trait 1]: [How it manifests in behavior]
2. [Trait 2]: [How it manifests in behavior]
3. [Trait 3]: [How it manifests in behavior]
4. [Trait 4]: [How it manifests in behavior]
5. [Trait 5]: [How it manifests in behavior]

### Values
- [Value 1]: [Why it matters to them]
- [Value 2]: [Why it matters to them]
- [Value 3]: [Why it matters to them]

### Fears/Vulnerabilities
- [Fear 1]: [How it affects their behavior]
- [Fear 2]: [How it affects their behavior]

### Motivations
- **Primary motivation**: [What drives them]
- **Secondary motivations**: [Supporting drives]

### Character Arc
- **Starting point**: [Where they begin]
- **Growth areas**: [How they evolve]
- **End goal**: [Where they're heading]

## Communication Style

### Speaking Patterns

**Vocabulary level**: [Simple/conversational/technical/academic]

**Sentence structure**: [Short and punchy/flowing/complex/varied]

**Pace**: [Fast/moderate/slow/varies by topic]

**Tone**: [Friendly/authoritative/casual/professional/humorous]

**Verbal tics**: [Specific phrases, filler words, speech patterns]
- [Tic 1]
- [Tic 2]
- [Tic 3]

**Catchphrases**: [Signature phrases they use regularly]
- "[Catchphrase 1]"
- "[Catchphrase 2]"
- "[Catchphrase 3]"

### Non-Verbal Communication

**Gestures**: [How they use hands, common movements]

**Facial expressions**: [Default expression, common expressions]

**Eye contact**: [Direct/avoidant/varies by context]

**Personal space**: [Close/distant/varies]

**Energy level**: [High/moderate/low/varies]

### Content-Specific Voice

**When teaching**: [How they explain concepts]

**When storytelling**: [Narrative style]

**When reacting**: [Emotional expression style]

**When selling/CTA**: [Persuasion approach]

## Expertise & Knowledge

### Areas of Expertise
1. [Domain 1]: [Depth of knowledge]
2. [Domain 2]: [Depth of knowledge]
3. [Domain 3]: [Depth of knowledge]

### Knowledge Gaps
- [What they don't know - makes them relatable]
- [What they're learning - shows growth]

### Teaching Style
- [How they break down complex topics]
- [Use of analogies, examples, demonstrations]

## Backstory

### Origin
[Where they came from, formative experiences]

### Journey
[Key milestones that shaped who they are]

### Current Situation
[Where they are now in their story]

### Future Direction
[Where they're heading, goals]

## Relationships

### Audience Relationship
- **How they view audience**: [Peers/students/friends/community]
- **Audience expectations**: [What viewers expect from them]
- **Boundaries**: [What they will/won't share]

### Other Characters (if applicable)
- [Character 1]: [Relationship dynamic]
- [Character 2]: [Relationship dynamic]

## Content Integration

### Content Types
- **Best suited for**: [Which content formats showcase this character best]
- **Avoid**: [Content types that don't fit the character]

### Typical Scenarios
1. [Scenario 1]: [How character behaves]
2. [Scenario 2]: [How character behaves]
3. [Scenario 3]: [How character behaves]

### Conflict & Challenge
- **Types of challenges**: [What obstacles they face]
- **How they respond**: [Problem-solving approach]
- **Growth moments**: [When they learn/change]

## Brand Alignment

### Brand Values Embodied
- [Value 1]: [How character represents it]
- [Value 2]: [How character represents it]
- [Value 3]: [How character represents it]

### Target Audience Resonance
- [Why this character appeals to target audience]
- [Specific audience pain points they address]

### Differentiation
- [What makes this character unique in the niche]
- [How they stand out from competitors]

## Production Notes

### AI Generation Consistency

**Sora 2 Cameos**:
- Generate character on white background
- Save as reusable asset
- Composite into different scenes

**Veo 3.1 Ingredients**:
- Upload facial engineering reference as ingredient
- Use for cross-scene consistency
- Maintain lighting/angle consistency

**Nanobanana Character JSON**:
- Save facial engineering JSON as template
- Reuse with different poses/expressions
- Maintain color palette consistency

### Visual Consistency Checklist
- [ ] Facial features match engineering spec
- [ ] Wardrobe aligns with character bible
- [ ] Expressions match personality traits
- [ ] Body language reflects character energy
- [ ] Color palette consistent across outputs
- [ ] Lighting style matches brand identity
- [ ] Post-processing consistent (film grain, color grade)

### Voice Consistency (if applicable)
- **Voice characteristics**: [Pitch, tone, accent, pace]
- **ElevenLabs voice ID**: [If using voice cloning]
- **Emotional range**: [How voice changes with emotion]

## Evolution & Updates

**Last updated**: [Date]

**Recent changes**:
- [Change 1]: [Reason]
- [Change 2]: [Reason]

**Planned evolution**:
- [Future change 1]: [Timeline]
- [Future change 2]: [Timeline]

## Reference Assets

**Image references**:
- [Link to facial engineering reference]
- [Link to full-body reference]
- [Link to wardrobe references]

**Video references**:
- [Link to character movement reference]
- [Link to expression reference]

**Voice references**:
- [Link to voice sample]
- [Link to emotional range demo]
```

## Character Context Profile

A lightweight version of the character bible optimized for AI prompt context. Use this when generating content featuring the character.

### Prompt-Ready Character Profile

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

### Example: Tech Educator Character

```text
CHARACTER: Alex Chen

VISUAL:
Face: 28-year-old East Asian, almond-shaped dark brown eyes (#3D2817), high cheekbones, straight nose, warm smile with dimples. Black hair (#1C1C1C) in undercut style. Wears black-framed glasses.
Body: 5'9", slim athletic build, confident upright posture
Wardrobe: Minimalist tech aesthetic - black turtlenecks, dark jeans, white sneakers. Signature silver watch.
Distinctive: Dimples when smiling, animated eyebrows, always wears glasses

PERSONALITY:
Core traits: Curious, patient, enthusiastic about teaching, slightly perfectionist, humble about expertise
Communication: Clear and concise, uses analogies from everyday life, asks rhetorical questions to engage audience
Energy: Moderate to high, calm but enthusiastic

EXPERTISE:
Knows: AI tools, productivity systems, content creation workflows
Teaching style: Breaks complex topics into simple steps, shows real examples, admits when something is difficult

VOICE:
Tone: Friendly expert - approachable but knowledgeable
Catchphrases: "Here's the thing...", "Let me show you exactly how", "This is game-changing"
Verbal tics: Pauses before key points, emphasizes "exactly" and "specifically"

CONTEXT:
Role: Tech educator and productivity expert
Relationship to audience: Peer who's a few steps ahead, sharing discoveries
Current arc: Transitioning from solo creator to building a community
```

## Sora 2 Cameos Workflow

Sora 2 Cameos allow you to generate a character once on a white background, then reuse them across multiple videos by compositing into different scenes.

### Cameo Generation Process

**Step 1: Generate Base Cameo**

```text
[Sora 2 Prompt]

Style: clean, professional, studio lighting, neutral, high-quality, contemporary, commercial aesthetic

Shot 1 (0-3s):
- Type: MS (medium shot)
- Angle: Eye-level, straight-on
- Movement: Static
- Focus: Subject, sharp focus throughout
- Composition: Centered, rule of thirds for headroom

Subject: [Paste character context profile VISUAL section]

Background: Pure white (#FFFFFF), seamless, no shadows, no texture, studio backdrop

Lighting:
- Type: Studio three-point lighting
- Direction: Key light 45° front-left, fill light 45° front-right, rim light from behind
- Quality: Soft diffused, even illumination, no harsh shadows
- Color temperature: Neutral (5500K)
- Mood: Professional, clean, commercial

Actions:
0.0s: Subject stands centered, neutral expression, looking at camera
0.5s: Slight smile begins to form
1.0s: Full genuine smile, eye contact maintained
1.5s: Subtle head tilt, friendly expression
2.0s: Returns to neutral, professional demeanor
2.5s: Slight nod, acknowledging viewer

Technical Specs:
Duration: 3 seconds
Aspect Ratio: 16:9
Resolution: 4K
Frame Rate: 30fps
Camera Model: Sony A7IV with 50mm f/1.8 lens
Settings: f/2.8, 1/200s, ISO 200

Negative Prompt: background elements, shadows on background, textured background, colored background, props, other people, motion blur, poor lighting, artifacts, distorted features
```

**Step 2: Extract and Clean**

1. Export cameo as 4K video with alpha channel (if supported) or clean white background
2. Use video editing software to key out white background (chroma key)
3. Save as transparent PNG sequence or video with alpha channel
4. Store in character asset library

**Step 3: Composite into Scenes**

```text
[Video Editing Workflow]

1. Generate or select background scene (location, environment)
2. Import character cameo with transparency
3. Scale and position character in scene
4. Match lighting:
   - Add shadows beneath character
   - Color grade character to match scene lighting
   - Add rim lighting if scene has backlight
5. Add depth:
   - Slight blur if character is in background
   - Sharpen if character is in foreground
   - Add atmospheric effects (fog, haze) if scene has them
6. Motion:
   - Add subtle camera movement to both character and background
   - Ensure character movement matches scene perspective
   - Add parallax if camera moves
```

### Cameo Library Organization

```text
characters/
├── [character-name]/
│   ├── cameos/
│   │   ├── neutral-front.mp4          # Neutral expression, front view
│   │   ├── smiling-front.mp4          # Smiling, front view
│   │   ├── talking-front.mp4          # Talking animation, front view
│   │   ├── neutral-side-left.mp4      # Neutral, left profile
│   │   ├── neutral-side-right.mp4     # Neutral, right profile
│   │   ├── gesturing-front.mp4        # Hand gestures, front view
│   │   └── walking-front.mp4          # Walking toward camera
│   ├── stills/
│   │   ├── portrait-front.png         # High-res portrait
│   │   ├── portrait-side.png          # Profile portrait
│   │   └── full-body.png              # Full body shot
│   ├── character-bible.md             # Full character bible
│   ├── character-profile.txt          # Prompt-ready profile
│   └── facial-engineering.json        # Facial engineering spec
```

## Veo 3.1 Ingredients Workflow

Veo 3.1 Ingredients provide superior character consistency for cinematic, high-production-value content. Upload a character face as an "ingredient" and Veo will maintain consistency across scenes.

### Ingredients Setup

**Step 1: Generate Reference Face**

Use Nanobanana Pro or Midjourney to generate a high-quality reference image:

```json
{
  "subject": "[Paste facial engineering description]",
  "concept": "Professional character reference portrait",
  "composition": {
    "framing": "close-up",
    "angle": "eye-level",
    "rule_of_thirds": true,
    "focal_point": "eyes",
    "depth_of_field": "shallow"
  },
  "lighting": {
    "type": "studio",
    "direction": "three-point",
    "quality": "soft diffused",
    "color_temperature": "neutral (5500K)",
    "mood": "bright and airy"
  },
  "style": {
    "aesthetic": "photorealistic",
    "texture": "smooth",
    "post_processing": "light grading"
  },
  "technical": {
    "resolution": "4K",
    "aspect_ratio": "1:1"
  }
}
```

**Step 2: Upload as Ingredient**

1. Access Veo 3.1 interface (via Higgsfield or direct API)
2. Navigate to Ingredients section
3. Upload character reference image
4. Name ingredient: `[character-name]-face`
5. Tag with character ID for easy retrieval

**Step 3: Use in Video Generation**

```text
[Veo 3.1 Prompt with Ingredients]

INGREDIENTS:
- Face: [character-name]-face

[Standard Veo 3.1 7-component prompt structure]

Technical Specs:
- Subject: Use ingredient [character-name]-face for character appearance
- Action: [Character actions and movements]
- Context: [Scene environment and setting]
- Camera Movement: [Camera work]
- Composition: [Shot composition]
- Lighting: [Lighting setup - must complement ingredient face lighting]
- Audio: [Audio design]

Negative Prompt: different face, face swap, altered features, inconsistent appearance
```

### Critical Veo 3.1 Rules

**ALWAYS use Ingredients-to-Video**:
- Upload face as ingredient
- Reference ingredient in prompt
- Maintain lighting consistency with ingredient

**NEVER use Frame-to-Video**:
- Produces grainy, yellow-tinted output
- Poor quality compared to ingredients workflow
- Inconsistent results

**Lighting Consistency**:
- Match scene lighting to ingredient reference lighting
- If ingredient has soft studio lighting, avoid harsh outdoor scenes
- If ingredient has warm lighting, maintain warm color temperature in scene

## Nanobanana Character JSON Templates

Save character specifications as reusable JSON templates for consistent image generation across different poses, expressions, and contexts.

### Character Template Structure

```json
{
  "template_name": "character-[name]-base",
  "template_version": "1.0",
  "character_id": "unique_identifier",
  
  "subject_base": "[Facial engineering description - 2-3 sentences]",
  
  "subject_variables": {
    "expression": "[neutral/smiling/serious/surprised/etc.]",
    "pose": "[standing/sitting/walking/gesturing/etc.]",
    "clothing": "[Specific outfit from character bible]",
    "context": "[Environment or activity]"
  },
  
  "composition": {
    "framing": "[variable based on use case]",
    "angle": "eye-level",
    "rule_of_thirds": true,
    "focal_point": "eyes",
    "depth_of_field": "shallow"
  },
  
  "lighting": {
    "type": "[consistent with brand identity]",
    "direction": "[consistent with brand identity]",
    "quality": "[consistent with brand identity]",
    "color_temperature": "[consistent with brand identity]",
    "mood": "[consistent with brand identity]"
  },
  
  "color": {
    "palette": ["[brand color 1]", "[brand color 2]", "[brand color 3]"],
    "dominant": "[brand primary]",
    "accent": "[brand accent]",
    "saturation": "[brand saturation level]",
    "harmony": "[brand color harmony]"
  },
  
  "style": {
    "aesthetic": "[brand aesthetic]",
    "texture": "[brand texture]",
    "post_processing": "[brand post-processing]",
    "reference": "[brand visual reference]"
  },
  
  "technical": {
    "camera": "[consistent camera model]",
    "lens": "[consistent lens choice]",
    "settings": "[consistent camera settings]",
    "resolution": "4K",
    "aspect_ratio": "[variable based on use case]"
  },
  
  "negative": "different face, altered features, inconsistent appearance, blurry, low quality, distorted, watermark"
}
```

### Usage: Generate Variations

To generate a new image with the same character in a different context:

```json
{
  "template": "character-alex-chen-base",
  
  "subject": "Alex Chen, 28-year-old East Asian with almond-shaped dark brown eyes, high cheekbones, black hair in undercut, black-framed glasses, wearing black turtleneck",
  
  "subject_variables": {
    "expression": "excited, genuine smile with dimples",
    "pose": "sitting at desk, leaning forward, hands gesturing enthusiastically",
    "clothing": "black turtleneck, silver watch visible",
    "context": "modern home office with MacBook and ring light"
  },
  
  "composition": {
    "framing": "medium shot",
    "angle": "eye-level",
    "rule_of_thirds": true,
    "focal_point": "eyes",
    "depth_of_field": "shallow"
  }
  
  [Rest of template remains consistent]
}
```

### Character Template Library

Organize templates by character and use case:

```text
templates/
├── characters/
│   ├── alex-chen/
│   │   ├── base.json                    # Base character template
│   │   ├── thumbnail-excited.json       # Thumbnail variant
│   │   ├── thumbnail-serious.json       # Thumbnail variant
│   │   ├── social-casual.json           # Social media variant
│   │   ├── professional-headshot.json   # Professional variant
│   │   └── action-teaching.json         # Teaching/demo variant
│   ├── sarah-martinez/
│   │   └── [similar structure]
│   └── [other-characters]/
```

## Brand Identity Consistency

Character consistency is part of broader brand visual consistency. Maintain these constants across all character outputs:

### Visual Constants

**Color Palette**:
```json
{
  "brand_colors": {
    "primary": "#HEX",
    "secondary": "#HEX",
    "accent": "#HEX",
    "neutral_light": "#HEX",
    "neutral_dark": "#HEX"
  },
  "usage": {
    "primary": "Character wardrobe, key brand elements",
    "secondary": "Backgrounds, supporting elements",
    "accent": "CTAs, highlights, emphasis",
    "neutral_light": "Backgrounds, text backgrounds",
    "neutral_dark": "Text, shadows, depth"
  }
}
```

**Lighting Style**:
- Consistent lighting direction across all character content
- Consistent color temperature (warm/neutral/cool)
- Consistent mood (bright and airy / dark and moody / high contrast)

**Post-Processing**:
- Consistent color grading (LUT or preset)
- Consistent film grain amount (if used)
- Consistent sharpness/softness
- Consistent contrast levels

**Camera Style**:
- Consistent camera models in prompts (affects rendering style)
- Consistent lens choices (affects perspective and depth)
- Consistent camera settings (affects bokeh and exposure look)

### Brand Identity Template

```json
{
  "brand_name": "[Your Brand]",
  "visual_identity": {
    "color_palette": {
      "primary": "#HEX",
      "secondary": "#HEX",
      "accent": "#HEX"
    },
    "lighting": {
      "type": "natural",
      "quality": "soft diffused",
      "color_temperature": "warm (4500K)",
      "mood": "bright and airy"
    },
    "post_processing": {
      "color_grade": "Warm and inviting with slight orange/teal split",
      "film_grain": "Subtle (10% opacity)",
      "contrast": "Medium (1.2x)",
      "saturation": "Slightly boosted (1.1x)"
    },
    "camera_aesthetic": {
      "camera": "Sony A7IV",
      "lens": "50mm f/1.8",
      "settings": "f/2.8, 1/200s, ISO 400"
    }
  },
  "apply_to": [
    "All character images",
    "All video content",
    "All thumbnails",
    "All social media graphics"
  ]
}
```

## Model Recency Arbitrage

**Key Principle**: Always use the latest-generation AI models. Older outputs get recognized as AI-generated faster as audiences become familiar with previous model artifacts.

### Model Lifecycle Strategy

**Current Generation (2026)**:
- Sora 2 Pro (released 2025)
- Veo 3.1 (released 2025)
- Nanobanana Pro (latest version)
- FLUX.1 Pro (latest version)
- Midjourney v7 (latest version)

**Upgrade Triggers**:
1. New model version released
2. Noticeable quality improvement
3. Better character consistency
4. Reduced artifacts
5. Faster generation times

**Migration Strategy**:

When a new model version is released:

1. **Test immediately**: Generate 10-20 samples with existing character specs
2. **Compare quality**: Side-by-side with previous model outputs
3. **Update templates**: Adjust prompts for new model's syntax/capabilities
4. **Regenerate key assets**: Update character cameos, reference images
5. **Document changes**: Note what improved, what changed, what to watch for

**Audience Perception Timeline**:
- **Months 0-3**: New model outputs look cutting-edge, audiences impressed
- **Months 3-6**: Audiences start recognizing model patterns, still acceptable
- **Months 6-12**: Model artifacts become familiar, "AI look" becomes obvious
- **Months 12+**: Outputs look dated, audiences immediately recognize as AI

**Competitive Advantage**:
- Early adopters of new models have 3-6 month quality advantage
- Competitors using older models have recognizable "AI look"
- Staying current = staying ahead of audience AI detection

### Model Update Checklist

When upgrading to a new model version:

- [ ] Test character consistency with new model
- [ ] Update facial engineering prompts if needed
- [ ] Regenerate character reference images
- [ ] Update Sora 2 Cameos with new model
- [ ] Update Veo 3.1 Ingredients with new model
- [ ] Update Nanobanana character JSON templates
- [ ] Regenerate thumbnail templates
- [ ] Update brand identity post-processing to match new model output
- [ ] Document new model quirks and best practices
- [ ] Archive old model outputs for comparison

## Character Consistency Verification

Before publishing content with characters, verify consistency across these dimensions:

### Visual Consistency Checklist

**Facial Features**:
- [ ] Face shape matches character bible
- [ ] Eye shape, color, and spacing match
- [ ] Nose shape and size match
- [ ] Mouth and lip shape match
- [ ] Skin tone and texture match
- [ ] Hair color, texture, and style match
- [ ] Distinctive features present (moles, scars, etc.)

**Body & Wardrobe**:
- [ ] Body type and build match
- [ ] Height proportions correct
- [ ] Wardrobe matches character bible
- [ ] Colors align with character palette
- [ ] Accessories present and correct
- [ ] Posture matches character energy

**Expression & Behavior**:
- [ ] Expressions match personality traits
- [ ] Body language reflects character energy
- [ ] Gestures align with character style
- [ ] Eye contact matches character profile
- [ ] Micro-expressions feel authentic to character

**Brand Alignment**:
- [ ] Lighting matches brand identity
- [ ] Color grading consistent with brand
- [ ] Post-processing matches brand style
- [ ] Overall aesthetic on-brand

### Cross-Content Consistency

When a character appears in multiple pieces of content:

**Same Scene/Series**:
- Exact same facial features
- Same wardrobe (unless story requires change)
- Same lighting style
- Same camera aesthetic

**Different Scenes/Episodes**:
- Consistent facial features
- Wardrobe variations within character style
- Lighting can vary by location but maintain brand mood
- Camera aesthetic consistent

**Different Platforms**:
- Facial features always consistent
- Wardrobe adapted to platform (professional for LinkedIn, casual for TikTok)
- Lighting adapted to platform norms while maintaining brand
- Format adapted (9:16 for TikTok, 16:9 for YouTube) but character consistent

## Integration with Content Pipeline

Characters flow through the content production pipeline:

### Pipeline Integration Points

**1. Research Phase** (`content/research.md`):
- Identify audience personas
- Determine what character traits will resonate
- Research competitor characters for differentiation

**2. Story Phase** (`content/story.md`):
- Develop character arc for content series
- Plan character-driven narratives
- Design character-audience relationship

**3. Production Phase**:
- **Writing** (`content/production/writing.md`): Write dialogue in character voice
- **Image** (`content/production/image.md`): Generate character portraits and thumbnails
- **Video** (`content/production/video.md`): Generate character video content
- **Audio** (`content/production/audio.md`): Clone character voice for consistency

**4. Distribution Phase** (`content/distribution/`):
- Adapt character presentation for each platform
- Maintain character consistency across channels
- Build character recognition across audience touchpoints

**5. Optimization Phase** (`content/optimization.md`):
- A/B test character variations
- Analyze which character traits drive engagement
- Iterate character based on audience response

## Common Character Consistency Issues

### Issue: Face Changes Between Generations

**Symptoms**:
- Different eye color or shape
- Different nose or mouth
- Different skin tone
- Different hair style

**Solutions**:
1. Use more detailed facial engineering description
2. Include hex codes for eye color and skin tone
3. Reference specific facial measurements
4. Use Veo 3.1 Ingredients instead of text prompts
5. Generate multiple variations and select most consistent

### Issue: Wardrobe Inconsistency

**Symptoms**:
- Different clothing colors
- Different style aesthetic
- Missing signature accessories

**Solutions**:
1. Include specific hex codes for wardrobe colors
2. List exact clothing items in prompt
3. Mention signature accessories explicitly
4. Use Nanobanana character JSON with wardrobe template
5. Generate character on white background, composite onto scenes

### Issue: Expression Doesn't Match Personality

**Symptoms**:
- Serious character smiling inappropriately
- Energetic character looking flat
- Expressions feel generic, not character-specific

**Solutions**:
1. Include personality traits in prompt
2. Specify exact expression and emotion
3. Reference character bible in generation prompt
4. Use emotional block cues for video
5. Generate multiple expressions, select most authentic

### Issue: Lighting/Style Inconsistency

**Symptoms**:
- Different lighting mood across outputs
- Different color grading
- Different post-processing look

**Solutions**:
1. Create brand identity template with exact lighting specs
2. Use same lighting parameters in all prompts
3. Apply consistent post-processing LUT
4. Include camera model and settings in all prompts
5. Batch generate content to maintain consistency

## Advanced Techniques

### Multi-Character Consistency

When managing multiple characters in the same content universe:

**Character Differentiation Matrix**:

| Character | Face Shape | Eye Color | Hair | Wardrobe | Personality | Voice |
|-----------|------------|-----------|------|----------|-------------|-------|
| Alex | Oval | Brown | Black | Minimalist | Analytical | Calm |
| Sarah | Heart | Green | Blonde | Colorful | Energetic | Upbeat |
| Marcus | Square | Blue | Brown | Professional | Authoritative | Deep |

**Consistency Rules**:
1. Each character has distinct visual markers
2. Characters maintain consistent relationship dynamics
3. Characters have complementary (not overlapping) expertise
4. Visual style consistent across all characters (same brand identity)

### Character Evolution Over Time

Characters can evolve while maintaining core consistency:

**What Can Change**:
- Wardrobe (seasonal, context-based)
- Hair style (gradual changes)
- Expressions (emotional growth)
- Expertise (learning new skills)
- Confidence (character arc)

**What Must Stay Consistent**:
- Facial bone structure
- Eye color and shape
- Skin tone
- Core personality traits
- Voice characteristics
- Distinctive features (moles, scars, etc.)

**Evolution Documentation**:

```markdown
# Character Evolution Log: [Character Name]

## Version 1.0 (Launch - Month 3)
- Initial character design
- Wardrobe: [Description]
- Personality: [Description]
- Expertise: [Description]

## Version 1.1 (Month 4 - Month 6)
**Changes**:
- Wardrobe updated to include [new element]
- Personality: Added more [trait]
- Expertise: Expanded into [new area]

**Reason**: [Why these changes were made]

**Audience Response**: [How audience reacted]

## Version 1.2 (Month 7 - Present)
[Continue documenting]
```

## Tools & Resources

### AI Generation Tools

**Image Generation**:
- Nanobanana Pro: Structured JSON prompts, style libraries
- Midjourney: Objects, environments, landscapes
- Freepik: Character-driven scenes
- Seedream 4: 4K refinement
- Ideogram: Face swap, text in images

**Video Generation**:
- Sora 2 Pro: UGC-style, authentic content
- Veo 3.1: Cinematic, character-consistent content
- Higgsfield: Multi-model video generation platform

**Voice Cloning**:
- ElevenLabs: Voice cloning and transformation
- CapCut: AI voice cleanup (use BEFORE ElevenLabs)

### Helper Scripts

```bash
# Character asset management (if implemented)
character-helper.sh create [name]           # Create new character bible
character-helper.sh generate [name] [type]  # Generate character asset
character-helper.sh verify [name]           # Check consistency across assets
character-helper.sh library                 # List all characters
```

### Related Documentation

- `content/production/image.md`: Image generation techniques
- `content/production/video.md`: Video generation workflows
- `content/production/audio.md`: Voice cloning and audio production
- `tools/vision/image-generation.md`: AI image model comparison
- `tools/video/video-prompt-design.md`: Video prompting frameworks
- `content/optimization.md`: A/B testing character variations

## Examples

### Example 1: YouTube Tech Channel Character

**Character**: TechSavvy Sam

**Facial Engineering Summary**:
- 32-year-old South Asian male
- Round face, warm smile, expressive eyebrows
- Dark brown eyes (#3D2817), black hair (#1C1C1C) with side part
- Warm skin tone (#C68642), clean-shaven
- Wears rectangular glasses

**Character Bible Highlights**:
- **Personality**: Enthusiastic, patient teacher, slightly nerdy, genuine
- **Wardrobe**: Casual tech aesthetic - graphic tees, hoodies, jeans
- **Voice**: Upbeat, uses analogies, catchphrase "Let me break this down"
- **Expertise**: Consumer tech, productivity tools, software tutorials

**Use Cases**:
- YouTube long-form tutorials (16:9)
- YouTube Shorts product reviews (9:16)
- Thumbnail variations (excited, serious, surprised)
- Social media clips across platforms

### Example 2: Fitness Brand Mascot

**Character**: FitLife Fiona

**Facial Engineering Summary**:
- 28-year-old Caucasian female
- Oval face, high cheekbones, athletic build
- Blue eyes (#4A90E2), blonde hair (#F5DEB3) in ponytail
- Fair skin tone (#F5D7C3), natural makeup
- Bright, energetic smile

**Character Bible Highlights**:
- **Personality**: Motivational, energetic, supportive, no-nonsense
- **Wardrobe**: Athletic wear in brand colors (teal and coral)
- **Voice**: Energetic, encouraging, uses "You've got this!" frequently
- **Expertise**: Fitness routines, nutrition basics, motivation

**Use Cases**:
- Workout demonstration videos
- Motivational social media posts
- Before/after transformation content
- Product endorsements

### Example 3: B2B SaaS Explainer Character

**Character**: DataDriven Dana

**Facial Engineering Summary**:
- 35-year-old Black female
- Heart-shaped face, intelligent expression
- Dark brown eyes (#2C1810), natural curly hair (#1A1A1A) shoulder-length
- Deep skin tone (#8D5524), professional appearance
- Confident, approachable demeanor

**Character Bible Highlights**:
- **Personality**: Analytical, clear communicator, patient, authoritative
- **Wardrobe**: Business casual - blazers, professional tops, minimal jewelry
- **Voice**: Clear and articulate, uses data-driven language, catchphrase "Let's look at the data"
- **Expertise**: Data analytics, business intelligence, SaaS platforms

**Use Cases**:
- Product demo videos
- Webinar presentations
- LinkedIn thought leadership content
- Case study explainers

## Workflow Summary

**Creating a New Character**:

1. Define character purpose and audience fit
2. Complete facial engineering analysis
3. Build comprehensive character bible
4. Generate reference assets (images, cameos, ingredients)
5. Create character JSON templates
6. Test consistency across multiple generations
7. Document in character library

**Using an Existing Character**:

1. Reference character bible for current specs
2. Load appropriate template (Nanobanana JSON, Sora Cameo, Veo Ingredient)
3. Adapt for specific use case (thumbnail, video, social post)
4. Generate content
5. Verify consistency against character bible
6. Publish and monitor audience response
7. Document any evolution or updates

**Maintaining Character Consistency**:

1. Regular consistency audits across published content
2. Update character bible when intentional changes made
3. Upgrade to latest AI models when available
4. Regenerate reference assets with new models
5. Monitor audience feedback for character resonance
6. Iterate based on performance data

---

**Last Updated**: 2026-02-10
**Version**: 1.0
**Related Tasks**: t199.7
