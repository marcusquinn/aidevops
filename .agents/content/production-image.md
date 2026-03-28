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

- **Primary Tools**: Nanobanana Pro (JSON prompts), Midjourney (objects/environments), Freepik (characters), Seedream 4 (4K refinement), Ideogram (face swap)
- **Key Techniques**: Style library system, annotated frame-to-video workflow, Shotdeck reference library, thumbnail factory pattern
- **Related**: `tools/vision/image-generation.md`, `content/production-video.md`, `content/optimization.md`

<!-- AI-CONTEXT-END -->

## Tool Routing

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

Structured JSON prompts enable **style library reuse** — save working JSON as named templates, swap `subject`/`concept`, maintain brand consistency.

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

Swap `subject`, `concept`, and `composition.focal_point` per shot; keep lighting, color, and style constant for brand consistency.

| Template | Use for | Camera / Lens | Aspect |
|----------|---------|---------------|--------|
| **Editorial Portrait** | Headshots, author bios | Canon R5, 85mm f/1.2, studio 3-point, 5500K | 4:5 |
| **Environmental Product** | E-commerce, lifestyle | Sony A7IV, 50mm f/1.8, golden hour, 3500K | 16:9 |
| **Magazine Cover** | YouTube thumbnails, hero images | Canon R5, 85mm f/1.2, dramatic front+rim | 9:16 |
| **Street Photography** | Authentic lifestyle, UGC aesthetic | Leica Q2, 28mm f/1.7, overcast, monochromatic | 3:2 |

## Style Library System

Save winning JSON templates with descriptive names (`brand-thumbnail-v1.json`). Reuse by swapping only `subject` and `concept`.

**Storage**: `~/.aidevops/.agent-workspace/work/[project]/style-library/` or version-control in your content repo.

| Category | Use Case | Key Attributes |
|----------|----------|----------------|
| **Thumbnails** | YouTube, blog headers | High contrast, bold colors, centered, 16:9 |
| **Social Graphics** | Instagram, Twitter, LinkedIn | Platform aspect ratios, vibrant, clear focal point |
| **Product Shots** | E-commerce, reviews | Clean backgrounds, natural lighting |
| **Character Portraits** | About pages, team bios | Professional lighting, neutral backgrounds |
| **Lifestyle** | Blog content, storytelling | Environmental context, natural lighting |
| **Editorial** | Magazine-style content | Dramatic lighting, bold composition |

## Thumbnail Factory Pattern

```bash
thumbnail-helper.sh generate "Your Video Topic" --count 10 --template high-contrast-face
thumbnail-helper.sh batch-score ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh ab-test VIDEO_ID ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh analyze VIDEO_ID
```

**Available templates**: `high-contrast-face`, `text-heavy`, `before-after`, `curiosity-gap`, `product-showcase`, `cinematic`, `minimalist`, `action-packed`

**Best practices**: Human faces increase CTR 30-40% (close-up, clear emotion). Must be readable at 320px. Leave 30% of frame clear for title text. Surprised/excited/curious expressions outperform neutral.

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

1. **Generate base frame** using Nanobanana Pro or Midjourney (16:9, subject in desired starting position)
2. **Annotate with motion indicators** — arrows (direction), labels (action descriptions), timing markers. Color-code: red = character, blue = camera, green = object
3. **Feed to video model** — Veo 3.1 or Sora 2. Prompt: "Animate this scene following the annotated motion indicators."
4. **Refine** — adjust annotations and regenerate if motion is incorrect

**Reference**: `content/production-video.md` for Veo 3.1 ingredients-to-video workflow (NOT frame-to-video, which produces grainy output).

## Shotdeck Reference Library Workflow

1. **Find reference on [Shotdeck](https://shotdeck.com/)** — search by mood, genre, or visual style
2. **Reverse-engineer with Gemini** — upload frame, prompt: "Analyze this cinematic frame. Describe composition, lighting, color palette (hex codes), camera settings, and mood. Output as structured data."
3. **Convert to Nanobanana JSON** — map analysis to JSON schema, adjust `subject` and `concept`, keep composition/lighting/color from reference

## Color, Camera, and Texture Reference

Always specify exact hex codes (not "blue" or "warm tones"). Use [Coolors.co](https://coolors.co/) or [Adobe Color](https://color.adobe.com/).

| Harmony | When to Use | Example Palette |
|---------|-------------|-----------------|
| **Monochromatic** | Professional, minimalist | #2C3E50, #34495E, #5D6D7E |
| **Analogous** | Natural, cohesive | #FF6B35, #F7931E, #FDC830 |
| **Complementary** | High contrast, bold | #FF6B35 (orange), #004E89 (blue) |
| **Triadic** | Vibrant, balanced | #FF6B35, #4ECDC4, #C44569 |

| Use Case | Camera | Lens | Settings | Texture |
|----------|--------|------|----------|---------|
| **Portrait** | Canon R5 | 85mm f/1.2 | f/1.8, 1/200s, ISO 200 | smooth |
| **Product** | Sony A7IV | 50mm f/1.8 | f/2.8, 1/250s, ISO 400 | digital clean |
| **Landscape** | Nikon Z9 | 16-35mm f/2.8 | f/8, 1/125s, ISO 100 | digital clean |
| **Street** | Leica Q2 | 28mm f/1.7 | f/5.6, 1/500s, ISO 800 | film grain |
| **Cinematic** | RED Komodo 6K | 35mm f/1.4 | f/2.0, 1/50s, ISO 800 | film grain |

## Midjourney, Freepik, Seedream 4, and Ideogram

**Midjourney**: `[SUBJECT] [ACTION] in [ENVIRONMENT], [LIGHTING], [STYLE], [CAMERA], --ar 16:9 --style raw --v 6 --no text, watermark` — always use `--style raw` for content production.

**Freepik**: Character-driven scenes (team photos, lifestyle, testimonials). Specify demographics, emotion, environment, and style.

**Seedream 4**: Post-processing upscale after Nanobanana/Midjourney/Freepik. Use for 4K print or video prep. Only refine images that passed initial quality checks.

**Ideogram**: Face swap for character consistency. Generate base portrait → upload as reference face → generate new scenes → face swap. Alternative: `content/production-characters.md` (Facial Engineering Framework).

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

**Formats**: JPG (photos), PNG (transparency/text overlays), WebP (modern web).

## UGC Brief Image Template

Generate keyframe images for each shot in a UGC storyboard. Each keyframe becomes a standalone social image or reference frame for the annotated frame-to-video workflow.

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

**Batch workflow**: Create base JSON → override `concept`, `composition.framing`, `composition.focal_point`, and `lighting` per shot → batch generate → score all (7.5+ threshold) → assemble visual shot list → annotate for video → feed to Sora 2 Pro (UGC) or Veo 3.1 (cinematic).

## Post-Processing with Enhancor AI

Use after generating images for professional-grade portrait enhancement, upscaling, and AI generation (Kora Pro).

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

**Best practices**: `skin_refinement_level` 40-60; `professional` mode for final deliverables; only enhance images that passed initial quality checks. Full API: `content/video-enhancor.md`.

## References

| Topic | File |
|-------|------|
| Brand identity / imagery style | `tools/design/brand-identity.md`, `context/brand-identity.toon` |
| Design catalogue (96 palettes, 67 UI styles) | `tools/design/ui-ux-catalogue.toon` |
| Model comparison (DALL-E 3, MJ, FLUX, SD XL) | `tools/vision/image-generation.md` |
| Video production / Veo 3.1 | `content/production-video.md` |
| Character consistency / Facial Engineering | `content/production-characters.md` |
| A/B testing / thumbnail analytics | `content/optimization.md` |
| UGC storyboard / hook formulas | `content/story.md` |
| 7-component video prompt format | `tools/video/video-prompt-design.md` |
| Portrait enhancement / Enhancor AI | `content/video-enhancor.md` |
| Vision AI decision tree | `tools/vision/overview.md` |
| Modify existing images | `tools/vision/image-editing.md` |
| Analyze images | `tools/vision/image-understanding.md` |
