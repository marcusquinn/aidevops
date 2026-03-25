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

Four ready-to-use templates — swap `subject` and `concept`, keep the rest for brand consistency:

| Template | Use for | Key settings |
|----------|---------|-------------|
| **Editorial Portrait** | Headshots, team photos, author bios | Canon R5, 85mm f/1.2, studio 3-point, neutral 5500K, 4:5 |
| **Environmental Product Shot** | E-commerce, lifestyle product placement | Sony A7IV, 50mm f/1.8, golden hour, warm 3500K, 16:9 |
| **Magazine Cover** | YouTube thumbnails, blog headers, hero images | Canon R5, 85mm f/1.2, dramatic front+rim, complementary palette, 9:16 |
| **Street Photography** | Authentic lifestyle, documentary, UGC aesthetic | Leica Q2, 28mm f/1.7, overcast available light, monochromatic, 3:2 |

Full JSON for each template: swap `subject`, `concept`, and `composition.focal_point` per shot. Keep lighting, color, and style constant for brand consistency.

**Example (Editorial Portrait)**:
```json
{
  "subject": "[NAME], a [AGE] [ETHNICITY] [GENDER] with [HAIR_DETAILS], wearing [CLOTHING]",
  "concept": "Professional editorial portrait for [CONTEXT]",
  "composition": { "framing": "medium shot", "angle": "eye-level", "rule_of_thirds": true, "focal_point": "eyes", "depth_of_field": "shallow" },
  "lighting": { "type": "studio", "direction": "three-point", "quality": "soft diffused", "color_temperature": "neutral (5500K)", "mood": "bright and airy" },
  "color": { "palette": ["#F5F5F5", "#2C3E50", "#E8E8E8"], "dominant": "#F5F5F5", "accent": "#2C3E50", "saturation": "muted", "harmony": "monochromatic" },
  "style": { "aesthetic": "editorial", "texture": "smooth", "post_processing": "light grading", "reference": "Annie Leibovitz editorial style" },
  "technical": { "camera": "Canon R5", "lens": "85mm f/1.2", "settings": "f/1.8, 1/200s, ISO 200", "resolution": "4K", "aspect_ratio": "4:5" },
  "negative": "blurry, low quality, distorted face, unnatural skin, oversaturated, harsh shadows, watermark"
}
```

## Style Library System

Save winning JSON templates with descriptive names (`brand-thumbnail-v1.json`, `product-lifestyle-v2.json`). Reuse by swapping only `subject` and `concept` — keep composition, lighting, color, and style constant.

**Storage**: `~/.aidevops/.agent-workspace/work/[project]/style-library/` or version-control in your content repo.

### Style Library Categories

| Category | Use Case | Key Attributes |
|----------|----------|----------------|
| **Thumbnails** | YouTube, blog headers | High contrast, bold colors, centered, 16:9 |
| **Social Graphics** | Instagram, Twitter, LinkedIn | Platform aspect ratios, vibrant, clear focal point |
| **Product Shots** | E-commerce, reviews | Clean backgrounds, natural lighting |
| **Character Portraits** | About pages, team bios | Professional lighting, neutral backgrounds |
| **Lifestyle** | Blog content, storytelling | Environmental context, natural lighting |
| **Editorial** | Magazine-style content | Dramatic lighting, bold composition |

## Thumbnail Factory Pattern

Generate 5-10 thumbnail variants per video/article at scale using style library templates.

### Automated Workflow

```bash
thumbnail-helper.sh generate "Your Video Topic" --count 10 --template high-contrast-face
thumbnail-helper.sh batch-score ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh ab-test VIDEO_ID ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh analyze VIDEO_ID
```

**Available templates**: `high-contrast-face`, `text-heavy`, `before-after`, `curiosity-gap`, `product-showcase`, `cinematic`, `minimalist`, `action-packed`

### Thumbnail Best Practices

- **Face prominence**: Human faces increase CTR by 30-40% (close-up, clear emotion)
- **High contrast**: Must be readable at 320px width
- **Text overlay space**: Leave 30% of frame clear for title text (add in post)
- **Emotion**: Surprised, excited, or curious expressions outperform neutral
- **Consistency**: Same style template across all channel content

### Thumbnail Scoring Rubric

| Criterion | Weight | What to Check |
|-----------|--------|---------------|
| **Face Prominence** | 25% | Visible, clear, emotionally expressive? |
| **Contrast** | 20% | Stands out in a thumbnail grid? |
| **Text Space** | 15% | Clear space for title overlay? |
| **Brand Alignment** | 15% | Matches channel visual identity? |
| **Emotion** | 15% | Evokes curiosity, surprise, or excitement? |
| **Clarity** | 10% | Readable at small sizes (320px)? |

**Threshold**: Only use thumbnails scoring 7.5+. Below 7.5 = regenerate.

## Annotated Frame-to-Video Workflow

Generate a static image, annotate it with motion indicators, then feed to video model for animation.

1. **Generate base frame** using Nanobanana Pro or Midjourney (16:9, subject in desired starting position)
2. **Annotate with motion indicators** — arrows (direction), labels (action descriptions), timing markers. Color-code: red = character, blue = camera, green = object
3. **Feed to video model** — Veo 3.1 (ingredients-to-video) or Sora 2. Prompt: "Animate this scene following the annotated motion indicators."
4. **Refine** — adjust annotations and regenerate if motion is incorrect

**Reference**: See `content/production/video.md` for Veo 3.1 ingredients-to-video workflow (NOT frame-to-video, which produces grainy output).

## Shotdeck Reference Library Workflow

[Shotdeck](https://shotdeck.com/) is a database of cinematic reference frames. Use it to reverse-engineer professional composition, lighting, and color grading.

1. **Find reference on Shotdeck** — search by mood, genre, or visual style
2. **Reverse-engineer with Gemini** — upload frame, prompt: "Analyze this cinematic frame. Describe composition, lighting, color palette (hex codes), camera settings, and mood. Output as structured data."
3. **Convert to Nanobanana JSON** — map Gemini's analysis to JSON schema, adjust `subject` and `concept`, keep composition/lighting/color from reference
4. **Generate** — result: your subject in the style of the cinematic reference

## Hex Color Code Precision

Always specify exact hex codes in JSON prompts. Avoid vague descriptions like "blue" or "warm tones."

### Color Harmony Rules

| Harmony Type | When to Use | Example Palette |
|--------------|-------------|-----------------|
| **Monochromatic** | Professional, minimalist | #2C3E50, #34495E, #5D6D7E |
| **Analogous** | Natural, cohesive | #FF6B35, #F7931E, #FDC830 |
| **Complementary** | High contrast, bold | #FF6B35 (orange), #004E89 (blue) |
| **Triadic** | Vibrant, balanced | #FF6B35, #4ECDC4, #C44569 |

**Tool**: [Coolors.co](https://coolors.co/) or [Adobe Color](https://color.adobe.com/) to generate palettes.

## Camera Settings in Prompts

Including camera settings improves photorealism and controls depth of field.

| Use Case | Camera | Lens | Settings | Effect |
|----------|--------|------|----------|--------|
| **Portrait** | Canon R5 | 85mm f/1.2 | f/1.8, 1/200s, ISO 200 | Shallow DOF, creamy bokeh |
| **Product** | Sony A7IV | 50mm f/1.8 | f/2.8, 1/250s, ISO 400 | Balanced sharpness |
| **Landscape** | Nikon Z9 | 16-35mm f/2.8 | f/8, 1/125s, ISO 100 | Deep DOF, sharp throughout |
| **Street** | Leica Q2 | 28mm f/1.7 | f/5.6, 1/500s, ISO 800 | Natural perspective, grainy |
| **Cinematic** | RED Komodo 6K | 35mm f/1.4 | f/2.0, 1/50s, ISO 800 | Film-like, shallow DOF |

## Texture Descriptions

| Texture | Description | Use Case |
|---------|-------------|----------|
| **Digital clean** | Smooth, sharp, no grain | Modern tech, corporate, minimalist |
| **Film grain** | Subtle grain, analog feel | Lifestyle, editorial, authentic |
| **Grainy** | Heavy grain, vintage | Street photography, documentary, retro |
| **Smooth** | Polished, no texture | Product shots, e-commerce |
| **Textured** | Visible surface detail | Artistic, tactile, handmade |

## Midjourney-Specific Prompting

```text
[SUBJECT] [doing ACTION] in [ENVIRONMENT], [LIGHTING], [STYLE], [CAMERA], --ar 16:9 --style raw --v 6 --no text, watermark
```

| Flag | Purpose |
|------|---------|
| `--ar 16:9` | Aspect ratio (16:9 video, 9:16 mobile, 1:1 square) |
| `--style raw` | Less stylized, more photorealistic — always use for content production |
| `--v 6` | Latest model version |
| `--no text, watermark` | Exclude unwanted elements |

## Freepik Character-Driven Workflow

Best for team photos, lifestyle content with people, testimonial visuals, social media with faces.

**Prompt tips**: Specify demographics (age, ethnicity, gender, clothing), emotion ("smiling confidently"), environment ("in a modern office"), and style ("professional photography").

## Seedream 4 Refinement

Post-processing step after generating with Nanobanana/Midjourney/Freepik. Use when: resolution is too low, need 4K for print, want enhanced details, or preparing for video generation.

**Cost**: Only refine images that passed initial quality checks.

## Ideogram Face Swap

Enables character consistency across multiple images. Workflow: generate base character portrait → upload to Ideogram as reference face → generate new scenes → face swap.

**Alternative**: See `content/production/characters.md` for Facial Engineering Framework.

## Platform-Specific Image Specs

| Platform | Dimensions | Aspect Ratio | Notes |
|----------|------------|--------------|-------|
| **YouTube Thumbnail** | 1280x720 | 16:9 | Max 2MB, high contrast |
| **Instagram Feed** | 1080x1080 | 1:1 | Square, vibrant colors |
| **Instagram Story** | 1080x1920 | 9:16 | Vertical, text-safe zones |
| **Twitter/X** | 1200x675 | 16:9 | Clear at small size |
| **LinkedIn** | 1200x627 | 1.91:1 | Professional aesthetic |
| **Pinterest** | 1000x1500 | 2:3 | Vertical, text overlay friendly |
| **Blog Header** | 1920x1080 | 16:9 | High res, SEO-optimized alt text |

**Formats**: JPG (photos, smaller size), PNG (transparency, text overlays), WebP (modern web).

## UGC Brief Image Template

Generate keyframe images for each shot in a UGC storyboard. Each keyframe becomes a standalone social image or reference frame for the annotated frame-to-video workflow.

### UGC Keyframe JSON Template

Extends the Street Photography Template with UGC-specific defaults. Swap `subject`, `concept`, and `composition.focal_point` per shot; keep the authentic UGC aesthetic constant.

```json
{
  "subject": "[PRESENTER_DESCRIPTION — identical across all shots]",
  "concept": "[SHOT_PURPOSE from storyboard]",
  "composition": { "framing": "[CU for hook/emotion, MS for dialogue, WS for context]", "angle": "eye-level", "rule_of_thirds": true, "focal_point": "[Per shot]", "depth_of_field": "shallow" },
  "lighting": { "type": "natural", "direction": "available light", "quality": "soft diffused", "color_temperature": "warm (4000K)", "mood": "authentic and approachable" },
  "color": { "palette": ["[BRAND_PRIMARY]", "[BRAND_SECONDARY]", "[NEUTRAL]"], "dominant": "[BRAND_PRIMARY]", "accent": "[BRAND_SECONDARY]", "saturation": "muted", "harmony": "analogous" },
  "style": { "aesthetic": "photorealistic", "texture": "film grain", "post_processing": "film emulation", "reference": "iPhone 15 Pro casual photography" },
  "technical": { "camera": "iPhone 15 Pro", "lens": "24mm f/1.78", "settings": "f/1.78, 1/120s, ISO 640", "resolution": "4K", "aspect_ratio": "[9:16 for TikTok/Reels | 16:9 for YouTube]" },
  "negative": "studio lighting, professional setup, staged, posed, oversaturated, digital artifacts, watermark, text overlays, perfect skin retouching"
}
```

### Per-Shot Keyframe Variations

| Shot | Framing | Focal Point | Concept Override | Lighting Override |
|------|---------|-------------|-----------------|-------------------|
| 1: Hook | CU | Eyes | "Pattern interrupt — [hook text]" | Warm natural, slightly bright |
| 2: Before State | MS | Presenter (frustrated) | "Pain point — [problem]" | Flat, slightly desaturated |
| 3: Product Hero | CU → MS | Product in hands | "Product reveal — [product name]" | Warm golden, product lit |
| 4: After State | CU | Face (satisfied) | "Transformation result — [outcome]" | Warm, rich, inviting |
| 5: CTA | MS | Presenter (direct to camera) | "Call to action — [CTA text]" | Clean, warm, confident |

### Batch Generation Workflow

1. Create base JSON with presenter description and UGC defaults
2. For each shot, override only: `concept`, `composition.framing`, `composition.focal_point`, and `lighting`
3. Batch generate via Nanobanana Pro API or sequential Midjourney prompts
4. Score all outputs (threshold 7.5+), regenerate any below
5. Assemble into visual shot list before committing to video generation

### Keyframe-to-Video Handoff

1. Score keyframes using Thumbnail Scoring Rubric (7.5+ threshold)
2. Annotate with motion per the Annotated Frame-to-Video Workflow
3. Feed to video model with the corresponding 7-component prompt from the storyboard
4. **Model selection**: Sora 2 Pro for UGC aesthetic, Veo 3.1 for cinematic

## Post-Processing Enhancement with Enhancor AI

After generating images, use **Enhancor AI** for professional-grade post-processing, especially for portrait content.

**When to use**: Professional headshots, social media profile pictures, print-ready enlargements, archival restoration, AI generation (Kora Pro).

```bash
# Professional headshot enhancement
enhancor-helper.sh enhance --img-url https://example.com/headshot.jpg \
    --model enhancorv3 --type face --skin-refinement 60 \
    --skin-realism 1.2 --portrait-depth 0.25 --resolution 2048 \
    --area-background --sync -o professional_headshot.png

# Portrait upscale
enhancor-helper.sh upscale --img-url https://example.com/portrait.jpg \
    --mode professional --sync -o upscaled.png

# Batch processing
enhancor-helper.sh batch --command enhance --input photoshoot.txt \
    --output-dir enhanced/ --model enhancorv3 --skin-refinement 50 --resolution 2048
```

**Capabilities**: Realistic skin enhancement (v1/v3), portrait upscaler, general image upscaler, detailed enhancement, Kora Pro AI generation (kora_pro, kora_pro_cinema; modes: normal, 2k_pro, 4k_ultra).

**Best practices**: Start with `skin_refinement_level` 40-60; use `professional` mode for final deliverables; only enhance images that passed initial quality checks.

Full API reference: `tools/video/enhancor.md`.

## Cross-References

- **Brand identity**: `tools/design/brand-identity.md` — check `context/brand-identity.toon` for imagery style before generating
- **Design catalogue**: `tools/design/ui-ux-catalogue.toon` — 96 colour palettes, 67 UI styles
- **Model comparison**: `tools/vision/image-generation.md` — DALL-E 3, Midjourney, FLUX, SD XL
- **Video production**: `content/production/video.md` — frame-to-video workflow, Veo 3.1
- **Character consistency**: `content/production/characters.md` — Facial Engineering Framework
- **A/B testing**: `content/optimization.md` — thumbnail variant testing, scoring, analytics
- **UGC storyboard**: `content/story.md` — UGC Brief Storyboard template
- **Video prompts**: `tools/video/video-prompt-design.md` — 7-component format
- **Enhancor AI**: `tools/video/enhancor.md` — portrait enhancement, upscaling, AI generation

## See Also

- `tools/vision/overview.md` — Vision AI decision tree
- `tools/vision/image-editing.md` — Modify existing images
- `tools/vision/image-understanding.md` — Analyze images
- `content/story.md` — Hook formulas, visual storytelling, UGC Brief Storyboard
- `content/research.md` — Audience research to inform visual style
