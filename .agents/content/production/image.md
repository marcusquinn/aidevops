---
name: image
description: AI image generation, thumbnails, style libraries, and visual asset production
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

# Image Production

AI-powered image generation for thumbnails, social media graphics, blog headers, product visuals, and brand assets using structured prompting and style libraries.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate consistent, high-quality images for content production pipeline
- **Primary Tools**: Nanobanana Pro (JSON prompts), Midjourney (objects/environments), Freepik (characters), Seedream 4 (4K refinement), Ideogram (face swap)
- **Key Techniques**: Style library system, annotated frame-to-video workflow, Shotdeck reference library, thumbnail factory pattern
- **Related**: `tools/vision/image-generation.md` (model comparison), `content/production/video.md` (frame-to-video), `content/optimization.md` (A/B testing)

**When to Use**: Creating thumbnails, social media graphics, blog headers, product mockups, character portraits, or any visual asset for content distribution.

<!-- AI-CONTEXT-END -->

## Tool Routing Decision Tree

Choose the right tool for your image generation task:

```text
Need structured JSON control?           → Nanobanana Pro
Need objects/environments/landscapes?   → Midjourney (--ar 16:9 --style raw)
Need character-driven scenes?           → Freepik
Need 4K refinement/upscaling?          → Seedream 4
Need face swap/character consistency?   → Ideogram
Need text in images?                    → DALL-E 3 or Ideogram
Need local/open-source?                 → FLUX.1 or SD XL (see tools/vision/image-generation.md)
```

## Nanobanana Pro JSON Prompt Schema

Nanobanana Pro uses structured JSON prompts for precise control over composition, lighting, color, and style. This enables **style library reuse** — save working JSON as named templates, swap subject/concept, maintain brand consistency.

### Core JSON Structure

```json
{
  "subject": "Primary subject description with physical details",
  "concept": "High-level creative direction or theme",
  "composition": {
    "framing": "close-up | medium shot | wide shot | extreme wide",
    "angle": "eye-level | low angle | high angle | dutch angle | bird's eye | worm's eye",
    "rule_of_thirds": true,
    "focal_point": "where viewer's eye should land",
    "depth_of_field": "shallow | medium | deep"
  },
  "lighting": {
    "type": "natural | studio | dramatic | soft | hard | rim | backlit",
    "direction": "front | side | back | top | bottom | three-point",
    "quality": "soft diffused | harsh direct | golden hour | blue hour | overcast",
    "color_temperature": "warm (3000K) | neutral (5500K) | cool (7000K)",
    "mood": "bright and airy | dark and moody | high contrast | low contrast"
  },
  "color": {
    "palette": ["#HEX1", "#HEX2", "#HEX3"],
    "dominant": "#HEX",
    "accent": "#HEX",
    "saturation": "vibrant | muted | desaturated | monochrome",
    "harmony": "complementary | analogous | triadic | monochromatic"
  },
  "style": {
    "aesthetic": "photorealistic | cinematic | editorial | minimalist | maximalist | vintage | modern",
    "texture": "smooth | grainy | film grain | digital clean",
    "post_processing": "none | light grading | heavy grading | film emulation",
    "reference": "Optional: photographer/artist style to emulate"
  },
  "technical": {
    "camera": "Sony A7IV | Canon R5 | RED Komodo | iPhone 15 Pro | etc.",
    "lens": "24mm f/1.4 | 50mm f/1.8 | 85mm f/1.2 | 16-35mm f/2.8",
    "settings": "f/2.8, 1/250s, ISO 400",
    "resolution": "4K | 8K | web-optimized",
    "aspect_ratio": "16:9 | 9:16 | 1:1 | 4:5"
  },
  "negative": "Elements to exclude: blurry, low quality, distorted, watermark, text, etc."
}
```

### Template Variants

#### 1. Editorial Portrait Template

Use for: Professional headshots, team photos, author bios, speaker profiles.

```json
{
  "subject": "[NAME], a [AGE] [ETHNICITY] [GENDER] with [HAIR_DETAILS], [EYE_COLOR] eyes, wearing [CLOTHING]",
  "concept": "Professional editorial portrait for [CONTEXT]",
  "composition": {
    "framing": "medium shot",
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
  "color": {
    "palette": ["#F5F5F5", "#2C3E50", "#E8E8E8"],
    "dominant": "#F5F5F5",
    "accent": "#2C3E50",
    "saturation": "muted",
    "harmony": "monochromatic"
  },
  "style": {
    "aesthetic": "editorial",
    "texture": "smooth",
    "post_processing": "light grading",
    "reference": "Annie Leibovitz editorial style"
  },
  "technical": {
    "camera": "Canon R5",
    "lens": "85mm f/1.2",
    "settings": "f/1.8, 1/200s, ISO 200",
    "resolution": "4K",
    "aspect_ratio": "4:5"
  },
  "negative": "blurry, low quality, distorted face, unnatural skin, oversaturated, harsh shadows, watermark"
}
```

#### 2. Environmental Product Shot Template

Use for: Product photography, e-commerce, lifestyle product placement.

```json
{
  "subject": "[PRODUCT] with [PHYSICAL_DETAILS]",
  "concept": "Lifestyle product shot in natural environment",
  "composition": {
    "framing": "medium shot",
    "angle": "slightly elevated (30 degrees)",
    "rule_of_thirds": true,
    "focal_point": "product center",
    "depth_of_field": "medium"
  },
  "lighting": {
    "type": "natural",
    "direction": "side",
    "quality": "golden hour",
    "color_temperature": "warm (3500K)",
    "mood": "warm and inviting"
  },
  "color": {
    "palette": ["#F4E4C1", "#8B7355", "#FFFFFF"],
    "dominant": "#F4E4C1",
    "accent": "#8B7355",
    "saturation": "vibrant",
    "harmony": "analogous"
  },
  "style": {
    "aesthetic": "cinematic",
    "texture": "film grain",
    "post_processing": "light grading",
    "reference": "Kinfolk magazine aesthetic"
  },
  "technical": {
    "camera": "Sony A7IV",
    "lens": "50mm f/1.8",
    "settings": "f/2.8, 1/250s, ISO 400",
    "resolution": "4K",
    "aspect_ratio": "16:9"
  },
  "negative": "studio background, artificial lighting, harsh shadows, cluttered, distracting elements, watermark"
}
```

#### 3. Magazine Cover Template

Use for: YouTube thumbnails, blog headers, social media hero images.

```json
{
  "subject": "[MAIN_SUBJECT] with [EXPRESSION/ACTION]",
  "concept": "Bold magazine cover style with high impact",
  "composition": {
    "framing": "close-up",
    "angle": "eye-level",
    "rule_of_thirds": false,
    "focal_point": "centered subject",
    "depth_of_field": "shallow"
  },
  "lighting": {
    "type": "dramatic",
    "direction": "front with rim light",
    "quality": "high contrast",
    "color_temperature": "neutral (5500K)",
    "mood": "high contrast"
  },
  "color": {
    "palette": ["#FF6B35", "#004E89", "#FFFFFF"],
    "dominant": "#004E89",
    "accent": "#FF6B35",
    "saturation": "vibrant",
    "harmony": "complementary"
  },
  "style": {
    "aesthetic": "modern",
    "texture": "digital clean",
    "post_processing": "heavy grading",
    "reference": "Vogue cover style"
  },
  "technical": {
    "camera": "Canon R5",
    "lens": "85mm f/1.2",
    "settings": "f/2.0, 1/200s, ISO 100",
    "resolution": "4K",
    "aspect_ratio": "9:16"
  },
  "negative": "blurry, low contrast, washed out colors, cluttered background, watermark, text overlays"
}
```

#### 4. Street Photography Template

Use for: Authentic lifestyle content, documentary-style visuals, UGC aesthetic.

```json
{
  "subject": "[SCENE_DESCRIPTION] with [HUMAN_ELEMENT]",
  "concept": "Candid street photography moment",
  "composition": {
    "framing": "wide shot",
    "angle": "eye-level",
    "rule_of_thirds": true,
    "focal_point": "human subject in environment",
    "depth_of_field": "deep"
  },
  "lighting": {
    "type": "natural",
    "direction": "available light",
    "quality": "overcast",
    "color_temperature": "neutral (5500K)",
    "mood": "authentic and raw"
  },
  "color": {
    "palette": ["#8B8B8B", "#D4D4D4", "#4A4A4A"],
    "dominant": "#8B8B8B",
    "accent": "#4A4A4A",
    "saturation": "desaturated",
    "harmony": "monochromatic"
  },
  "style": {
    "aesthetic": "photorealistic",
    "texture": "grainy",
    "post_processing": "film emulation",
    "reference": "Henri Cartier-Bresson street photography"
  },
  "technical": {
    "camera": "Leica Q2",
    "lens": "28mm f/1.7",
    "settings": "f/5.6, 1/500s, ISO 800",
    "resolution": "4K",
    "aspect_ratio": "3:2"
  },
  "negative": "staged, posed, studio lighting, oversaturated, digital artifacts, watermark"
}
```

## Style Library System

The **Style Library** is a collection of saved JSON templates that maintain brand consistency across all visual content. Instead of re-engineering prompts from scratch, swap the `subject` and `concept` fields while keeping composition, lighting, color, and style constant.

### Building Your Style Library

1. **Generate test images** using the templates above
2. **Score outputs** on brand alignment, visual quality, and platform performance
3. **Save winning templates** with descriptive names: `brand-thumbnail-v1.json`, `product-lifestyle-v2.json`, `editorial-portrait-v1.json`
4. **Categorize by use case**: thumbnails, social graphics, blog headers, product shots, character portraits
5. **Version control**: Track template iterations (`v1`, `v2`, `v3`) as you refine

### Style Library Categories

| Category | Use Case | Key Attributes |
|----------|----------|----------------|
| **Thumbnails** | YouTube, blog headers | High contrast, bold colors, centered composition, 16:9 |
| **Social Graphics** | Instagram, Twitter, LinkedIn | Platform-specific aspect ratios, vibrant colors, clear focal point |
| **Product Shots** | E-commerce, reviews | Clean backgrounds, natural lighting, product-focused |
| **Character Portraits** | About pages, team bios | Professional lighting, neutral backgrounds, editorial style |
| **Lifestyle** | Blog content, storytelling | Environmental context, natural lighting, authentic feel |
| **Editorial** | Magazine-style content | Dramatic lighting, bold composition, high production value |

### Reusing Templates

**Example workflow**:

1. Start with `brand-thumbnail-v3.json` (proven template with 4.2% CTR)
2. Swap `subject`: `"A laptop on a desk"` → `"A smartphone in hand"`
3. Adjust `concept`: `"Productivity setup"` → `"Mobile workflow"`
4. Keep all other fields (lighting, color, style) identical
5. Generate → instant brand-consistent output

**Storage**: Save templates in `~/.aidevops/.agent-workspace/work/[project]/style-library/` or version-control them in your content repo.

## Thumbnail Factory Pattern

The **Thumbnail Factory** is a production system for generating 5-10 thumbnail variants per video/article at scale using style library templates.

### Automated Workflow (via `thumbnail-helper.sh`)

The `thumbnail-helper.sh` script automates the entire thumbnail A/B testing pipeline:

```bash
# 1. Generate 10 thumbnail variants with a specific template
thumbnail-helper.sh generate "Your Video Topic" --count 10 --template high-contrast-face

# 2. Download generated images from Higgsfield UI to the output directory

# 3. Score all variants using the rubric below
thumbnail-helper.sh batch-score ~/.cache/aidevops/thumbnails/[output_dir]/

# 4. Upload passing thumbnails (score >= 7.5) for A/B testing
thumbnail-helper.sh ab-test VIDEO_ID ~/.cache/aidevops/thumbnails/[output_dir]/

# 5. Analyze performance after 1000+ impressions
thumbnail-helper.sh analyze VIDEO_ID
```

**Available templates**: `high-contrast-face`, `text-heavy`, `before-after`, `curiosity-gap`, `product-showcase`, `cinematic`, `minimalist`, `action-packed`

### Manual Workflow

1. **Script/outline complete** → Extract 3-5 key visual moments
2. **Select style template** → Use proven thumbnail template from style library
3. **Generate variants** → Swap subject/concept for each key moment
4. **Batch generate** → Use Nanobanana Pro API or Midjourney batch mode
5. **Score outputs** → Evaluate on: face prominence, text readability, contrast, emotion, brand alignment
6. **A/B test** → Upload top 3-5 to platform for testing (see `content/optimization.md`)

### Thumbnail Best Practices

- **Face prominence**: Human faces increase CTR by 30-40% (close-up, clear emotion)
- **High contrast**: Thumbnail must be readable at 320px width
- **Bold colors**: Use brand accent colors for instant recognition
- **Text overlay space**: Leave 30% of frame clear for title text (add in post, not in generation)
- **Emotion**: Surprised, excited, or curious expressions outperform neutral
- **Consistency**: Use same style template across all channel content for brand recognition

### Thumbnail Scoring Rubric

Score each generated thumbnail on these criteria (1-10 scale):

| Criterion | Weight | What to Check |
|-----------|--------|---------------|
| **Face Prominence** | 25% | Is face visible, clear, and emotionally expressive? |
| **Contrast** | 20% | Does it stand out in a grid of thumbnails? |
| **Text Space** | 15% | Is there clear space for title overlay? |
| **Brand Alignment** | 15% | Does it match channel/brand visual identity? |
| **Emotion** | 15% | Does it evoke curiosity, surprise, or excitement? |
| **Clarity** | 10% | Is it readable at small sizes (320px)? |

**Threshold**: Only use thumbnails scoring 7.5+ overall. Below 7.5 = regenerate.

## Annotated Frame-to-Video Workflow

Generate a static image, annotate it with motion indicators, then feed to video model for animation. This workflow gives precise control over composition before committing to video generation.

### Steps

1. **Generate base frame** using Nanobanana Pro or Midjourney
   - Use JSON template for exact composition control
   - Generate at 16:9 aspect ratio for video compatibility
   - Ensure subject is in desired starting position

2. **Annotate with motion indicators**
   - Use image editing tool (Photoshop, Figma, Canva) to add:
     - **Arrows**: Direction of movement (character walks left, camera pans right)
     - **Labels**: Action descriptions ("character picks up cup", "camera zooms in")
     - **Timing markers**: "0-2s: character enters", "2-4s: camera follows"
   - Color-code annotations: red = character movement, blue = camera movement, green = object interaction

3. **Feed to video model**
   - Upload annotated frame to Veo 3.1 (ingredients-to-video) or Sora 2
   - Prompt: "Animate this scene following the annotated motion indicators. [DESCRIBE ACTIONS]"
   - Video model interprets annotations and generates motion

4. **Refine**
   - If motion is incorrect, adjust annotations and regenerate
   - Cheaper than regenerating video from scratch

**Use case**: Complex scenes with specific choreography, product demos with precise movements, multi-step actions.

**Reference**: See `content/production/video.md` for Veo 3.1 ingredients-to-video workflow (NOT frame-to-video, which produces grainy output).

## Shotdeck Reference Library Workflow

[Shotdeck](https://shotdeck.com/) is a database of cinematic reference frames from films. Use it to reverse-engineer professional composition, lighting, and color grading.

### Workflow

1. **Find reference on Shotdeck**
   - Search by mood, genre, or visual style
   - Download high-res frame

2. **Reverse-engineer with Gemini**
   - Upload frame to Gemini 2.0 Flash or Pro
   - Prompt: "Analyze this cinematic frame. Describe: composition (framing, angle, rule of thirds), lighting (type, direction, quality, color temperature), color palette (hex codes), camera settings (lens, aperture, focal length), and mood. Output as structured data."

3. **Convert to Nanobanana JSON**
   - Take Gemini's analysis and map to JSON schema
   - Adjust `subject` and `concept` for your content
   - Keep composition, lighting, and color from reference

4. **Generate**
   - Use Nanobanana Pro with reference-based JSON
   - Result: Your subject in the style of the cinematic reference

**Example**:

- **Reference**: Blade Runner 2049 neon-lit street scene
- **Gemini analysis**: "Low angle, wide shot, neon pink and cyan color palette (#FF006E, #00D9FF), backlit with rim lighting, f/2.8 shallow depth of field, moody and atmospheric"
- **Your JSON**: Keep lighting/color/composition, swap subject to "A developer at a desk with dual monitors"
- **Result**: Developer scene with Blade Runner aesthetic

## Hex Color Code Precision

Always specify exact hex codes in JSON prompts for brand consistency. Avoid vague color descriptions like "blue" or "warm tones."

### Brand Color Palette Template

```json
{
  "brand_colors": {
    "primary": "#HEX",
    "secondary": "#HEX",
    "accent": "#HEX",
    "neutral_light": "#HEX",
    "neutral_dark": "#HEX"
  },
  "use_cases": {
    "thumbnails": ["primary", "accent"],
    "social_graphics": ["secondary", "accent"],
    "product_shots": ["neutral_light", "primary"],
    "editorial": ["neutral_dark", "accent"]
  }
}
```

### Color Harmony Rules

| Harmony Type | When to Use | Example Palette |
|--------------|-------------|-----------------|
| **Monochromatic** | Professional, minimalist | #2C3E50, #34495E, #5D6D7E |
| **Analogous** | Natural, cohesive | #FF6B35, #F7931E, #FDC830 |
| **Complementary** | High contrast, bold | #FF6B35 (orange), #004E89 (blue) |
| **Triadic** | Vibrant, balanced | #FF6B35, #4ECDC4, #C44569 |

**Tool**: Use [Coolors.co](https://coolors.co/) or [Adobe Color](https://color.adobe.com/) to generate palettes, then extract hex codes for JSON.

## Camera Settings in Prompts

Including camera settings (lens, aperture, ISO) in prompts improves photorealism and gives control over depth of field and bokeh.

### Common Camera/Lens Combinations

| Use Case | Camera | Lens | Settings | Effect |
|----------|--------|------|----------|--------|
| **Portrait** | Canon R5 | 85mm f/1.2 | f/1.8, 1/200s, ISO 200 | Shallow DOF, creamy bokeh |
| **Product** | Sony A7IV | 50mm f/1.8 | f/2.8, 1/250s, ISO 400 | Balanced sharpness |
| **Landscape** | Nikon Z9 | 16-35mm f/2.8 | f/8, 1/125s, ISO 100 | Deep DOF, sharp throughout |
| **Street** | Leica Q2 | 28mm f/1.7 | f/5.6, 1/500s, ISO 800 | Natural perspective, grainy |
| **Cinematic** | RED Komodo 6K | 35mm f/1.4 | f/2.0, 1/50s, ISO 800 | Film-like, shallow DOF |

**Prompt example**: `"Shot on Canon R5 with 85mm f/1.2 lens at f/1.8, 1/200s, ISO 200. Shallow depth of field with creamy bokeh."`

## Texture Descriptions

Texture keywords control the "feel" of the image — smooth digital, grainy film, or textured analog.

### Texture Vocabulary

| Texture | Description | Use Case |
|---------|-------------|----------|
| **Digital clean** | Smooth, sharp, no grain | Modern tech, corporate, minimalist |
| **Film grain** | Subtle grain, analog feel | Lifestyle, editorial, authentic |
| **Grainy** | Heavy grain, vintage | Street photography, documentary, retro |
| **Smooth** | Polished, no texture | Product shots, e-commerce, professional |
| **Textured** | Visible surface detail | Artistic, tactile, handmade |

**Prompt example**: `"Film grain texture with subtle analog feel, shot on Kodak Portra 400"`

## Midjourney-Specific Prompting

When using Midjourney (for objects/environments/landscapes), use these flags:

### Essential Flags

| Flag | Purpose | Example |
|------|---------|---------|
| `--ar 16:9` | Aspect ratio | `--ar 16:9` (video), `--ar 9:16` (mobile), `--ar 1:1` (square) |
| `--style raw` | Less stylized, more photorealistic | Always use for content production |
| `--v 6` | Model version | Use latest version (v6 as of 2024) |
| `--no text, watermark` | Negative prompt | Exclude unwanted elements |

### Midjourney Prompt Structure

```text
[SUBJECT] [doing ACTION] in [ENVIRONMENT], [LIGHTING], [STYLE], [CAMERA], --ar 16:9 --style raw --v 6 --no text, watermark
```

**Example**:

```text
A laptop on a wooden desk in a modern home office, natural window light from the left, minimalist aesthetic, shot on Sony A7IV with 50mm lens, --ar 16:9 --style raw --v 6 --no text, watermark, clutter
```

## Freepik Character-Driven Workflow

Freepik excels at character-driven scenes with consistent human subjects. Use for:

- Team photos
- Lifestyle content with people
- Testimonial visuals
- Social media graphics with faces

### Freepik Prompt Tips

1. **Be specific about demographics**: Age, ethnicity, gender, clothing style
2. **Describe emotion clearly**: "smiling confidently", "looking surprised", "focused and determined"
3. **Specify environment**: "in a modern office", "outdoors in a park", "at a coffee shop"
4. **Use style keywords**: "professional photography", "lifestyle photography", "editorial style"

**Example**: `"A 30-year-old Asian woman with long black hair, wearing a white blouse, smiling confidently at the camera, in a modern office with natural light, professional photography style"`

## Seedream 4 Refinement

Seedream 4 is a 4K upscaling and refinement model. Use it as a **post-processing step** after generating with Nanobanana, Midjourney, or Freepik.

### When to Use Seedream 4

- Generated image is good but resolution is too low
- Need 4K output for print or high-res web
- Want to enhance details (facial features, textures, sharpness)
- Preparing images for video generation (higher res = better video quality)

### Workflow

1. Generate base image with Nanobanana/Midjourney/Freepik
2. Upload to Seedream 4
3. Prompt: "Upscale to 4K resolution, enhance details, maintain original composition and style"
4. Download refined 4K output

**Cost consideration**: Only refine images that passed initial quality checks. Don't upscale every generation.

## Ideogram Face Swap

Ideogram's face swap feature enables **character consistency** across multiple images. Use for:

- Multi-image campaigns with the same character
- Before/after comparisons
- Character-driven storytelling
- Brand mascots or spokespeople

### Workflow

1. **Generate base character portrait** with Nanobanana or Freepik
2. **Upload to Ideogram** as reference face
3. **Generate new scenes** with different backgrounds/actions
4. **Face swap** to maintain character consistency

**Alternative**: See `content/production/characters.md` for Facial Engineering Framework (exhaustive facial analysis for consistency across 100+ outputs).

## Platform-Specific Image Specs

Different platforms have different optimal image dimensions and aspect ratios.

### Social Media Specs

| Platform | Format | Dimensions | Aspect Ratio | Notes |
|----------|--------|------------|--------------|-------|
| **YouTube Thumbnail** | JPG/PNG | 1280x720 | 16:9 | Max 2MB, high contrast |
| **Instagram Feed** | JPG/PNG | 1080x1080 | 1:1 | Square, vibrant colors |
| **Instagram Story** | JPG/PNG | 1080x1920 | 9:16 | Vertical, text-safe zones |
| **Twitter/X** | JPG/PNG | 1200x675 | 16:9 | Landscape, clear at small size |
| **LinkedIn** | JPG/PNG | 1200x627 | 1.91:1 | Professional aesthetic |
| **Facebook** | JPG/PNG | 1200x630 | 1.91:1 | Similar to LinkedIn |
| **Pinterest** | JPG/PNG | 1000x1500 | 2:3 | Vertical, text overlay friendly |
| **Blog Header** | JPG/PNG | 1920x1080 | 16:9 | High res, SEO-optimized alt text |

### File Format Guidelines

- **JPG**: Photographs, complex images, smaller file size
- **PNG**: Graphics with transparency, text overlays, logos
- **WebP**: Modern format, smaller than JPG, use for web when supported

## UGC Brief Image Template

Generate keyframe images for each shot in a UGC storyboard (from `content/story.md` UGC Brief Storyboard). Each keyframe becomes either a standalone social image or a reference frame for video generation via the annotated frame-to-video workflow.

### When to Use

- Generating static keyframes before committing to video generation (cheaper iteration)
- Creating social media stills from a storyboard (Instagram carousel, blog headers)
- Producing reference frames for the annotated frame-to-video workflow (see above)
- Building a visual shot list for a video editor or director

### UGC Keyframe JSON Template

This template extends the Street Photography Template (above) with UGC-specific defaults. Swap `subject`, `concept`, and `composition.focal_point` per shot while keeping the authentic UGC aesthetic constant.

```json
{
  "subject": "[PRESENTER_DESCRIPTION — identical across all shots]",
  "concept": "[SHOT_PURPOSE from storyboard — e.g., 'Hook: presenter reacts to bold claim']",
  "composition": {
    "framing": "[Per shot: CU for hook/emotion, MS for dialogue, WS for context]",
    "angle": "eye-level",
    "rule_of_thirds": true,
    "focal_point": "[Per shot: eyes for hook, product for hero, presenter for CTA]",
    "depth_of_field": "shallow"
  },
  "lighting": {
    "type": "natural",
    "direction": "available light",
    "quality": "soft diffused",
    "color_temperature": "warm (4000K)",
    "mood": "authentic and approachable"
  },
  "color": {
    "palette": ["[BRAND_PRIMARY]", "[BRAND_SECONDARY]", "[NEUTRAL]"],
    "dominant": "[BRAND_PRIMARY]",
    "accent": "[BRAND_SECONDARY]",
    "saturation": "muted",
    "harmony": "analogous"
  },
  "style": {
    "aesthetic": "photorealistic",
    "texture": "film grain",
    "post_processing": "film emulation",
    "reference": "iPhone 15 Pro casual photography"
  },
  "technical": {
    "camera": "iPhone 15 Pro",
    "lens": "24mm f/1.78",
    "settings": "f/1.78, 1/120s, ISO 640",
    "resolution": "4K",
    "aspect_ratio": "[9:16 for TikTok/Reels | 16:9 for YouTube]"
  },
  "negative": "studio lighting, professional setup, staged, posed, oversaturated, digital artifacts, watermark, text overlays, perfect skin retouching"
}
```

### Per-Shot Keyframe Variations

Map each storyboard shot to specific JSON overrides:

| Shot | Framing | Focal Point | Concept Override | Lighting Override |
|------|---------|-------------|-----------------|-------------------|
| 1: Hook | CU | Eyes | "Pattern interrupt — [hook text]" | Warm natural, slightly bright |
| 2: Before State | MS | Presenter (frustrated) | "Pain point — [problem]" | Flat, slightly desaturated |
| 3: Product Hero | CU → MS | Product in hands | "Product reveal — [product name]" | Warm golden, product lit |
| 4: After State | CU | Face (satisfied) | "Transformation result — [outcome]" | Warm, rich, inviting |
| 5: CTA | MS | Presenter (direct to camera) | "Call to action — [CTA text]" | Clean, warm, confident |

### Worked Example: FreshBrew Shot 3 (Product Hero)

Using the FreshBrew storyboard from `content/story.md`:

```json
{
  "subject": "Maya, a 32-year-old South Asian woman with shoulder-length dark wavy hair, warm brown eyes, light olive skin, wearing a cream knit sweater over a white tee, relaxed posture, genuine warm smile, minimal gold stud earrings, natural makeup",
  "concept": "Product reveal — Maya opens FreshBrew subscription box with visible excitement, colourful coffee bags inside",
  "composition": {
    "framing": "medium shot",
    "angle": "eye-level",
    "rule_of_thirds": true,
    "focal_point": "FreshBrew box and coffee bags in hands",
    "depth_of_field": "shallow"
  },
  "lighting": {
    "type": "natural",
    "direction": "side (window light from left)",
    "quality": "golden hour",
    "color_temperature": "warm (3500K)",
    "mood": "warm and inviting"
  },
  "color": {
    "palette": ["#F4E4C1", "#6B4226", "#D4A574"],
    "dominant": "#F4E4C1",
    "accent": "#6B4226",
    "saturation": "muted",
    "harmony": "analogous"
  },
  "style": {
    "aesthetic": "photorealistic",
    "texture": "film grain",
    "post_processing": "film emulation",
    "reference": "iPhone 15 Pro casual photography"
  },
  "technical": {
    "camera": "iPhone 15 Pro",
    "lens": "24mm f/1.78",
    "settings": "f/1.78, 1/120s, ISO 640",
    "resolution": "4K",
    "aspect_ratio": "9:16"
  },
  "negative": "studio lighting, professional setup, staged, posed, oversaturated, digital artifacts, watermark, text overlays, perfect skin retouching, blurry product text"
}
```

### Keyframe-to-Video Handoff

After generating keyframe images:

1. **Score keyframes** using the Thumbnail Scoring Rubric (above) — threshold 7.5+
2. **Annotate with motion** — Add arrows and labels per the Annotated Frame-to-Video Workflow (above)
3. **Feed to video model** — Use the corresponding 7-component prompt from the storyboard
4. **Model selection**: Sora 2 Pro for UGC aesthetic, Veo 3.1 for cinematic (see `content/production/video.md`)

### Batch Generation Workflow

Generate all 5 keyframes in a single session:

1. Create base JSON with presenter description and UGC defaults (template above)
2. For each shot, override only: `concept`, `composition.framing`, `composition.focal_point`, and `lighting` per the Per-Shot Keyframe Variations table
3. Batch generate via Nanobanana Pro API or sequential Midjourney prompts
4. Score all outputs, regenerate any below 7.5
5. Assemble into a visual shot list for review before committing to video generation

## Cross-References

- **Model comparison**: `tools/vision/image-generation.md` — detailed comparison of DALL-E 3, Midjourney, FLUX, SD XL
- **Video production**: `content/production/video.md` — frame-to-video workflow, Veo 3.1 ingredients
- **Character consistency**: `content/production/characters.md` — Facial Engineering Framework, character bibles
- **A/B testing**: `content/optimization.md` — thumbnail variant testing, scoring, analytics
- **Distribution**: `content/distribution/` — platform-specific formatting for YouTube, social, blog
- **UGC storyboard**: `content/story.md` — UGC Brief Storyboard template (generates the shot list this template visualises)
- **Video prompts**: `tools/video/video-prompt-design.md` — 7-component format for video generation from keyframes

## See Also

- `tools/vision/overview.md` — Vision AI decision tree
- `tools/vision/image-editing.md` — Modify existing images
- `tools/vision/image-understanding.md` — Analyze images
- `content/story.md` — Hook formulas, visual storytelling frameworks, and UGC Brief Storyboard
- `content/research.md` — Audience research to inform visual style
