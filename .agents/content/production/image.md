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

AI-powered image generation for thumbnails, visual assets, and content production at scale using structured prompts, style libraries, and tool routing.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Generate consistent, high-quality images for content production
- **Primary tools**: Nanobanana Pro (structured JSON), Midjourney (objects/environments), Freepik (characters), Seedream 4 (4K refinement), Ideogram (face swap)
- **Key patterns**: Style Library System, Thumbnail Factory, Annotated Frame-to-Video, Shotdeck Reference
- **Output**: Production-ready images with consistent brand style across all outputs
- **Related**: `tools/vision/image-generation.md` (tool details), `content/production/video.md` (frame-to-video workflow), `content/production/characters.md` (character consistency)

<!-- AI-CONTEXT-END -->

## Tool Routing

Choose the right tool for the job based on content type and requirements.

### Decision Tree

```text
Need structured JSON prompts with 4 template variants?
  → Nanobanana Pro (editorial, environmental, magazine cover, street photography)

Need objects, environments, or landscapes (16:9)?
  → Midjourney (--ar 16:9 --style raw)

Need character-driven scenes with facial consistency?
  → Freepik → Seedream 4 (4K refinement) → Veo 3.1 (ingredients)

Need 4K upscaling and refinement?
  → Seedream 4

Need face swap or character replacement?
  → Ideogram

Need cinematic reference reverse-engineering?
  → Shotdeck → Gemini → prompt extraction
```

### Tool Comparison

| Tool | Best For | Strengths | Limitations | Cost |
|------|----------|-----------|-------------|------|
| **Nanobanana Pro** | Structured JSON prompts, consistent style | 4 template variants, hex color precision, camera settings | Requires JSON schema knowledge | API pricing |
| **Midjourney** | Objects, environments, landscapes | Photorealistic quality, 16:9 aspect ratio, --style raw | No API (Discord/web only), no character consistency | $10-60/mo |
| **Freepik** | Character-driven scenes | Good facial features, diverse poses | Lower resolution (needs refinement) | Free tier + paid |
| **Seedream 4** | 4K refinement | Upscales to 4K, enhances details | Requires input image | API pricing |
| **Ideogram** | Face swap, text in images | Character replacement, logo generation | Limited to specific use cases | Free tier + paid |

## Nanobanana Pro JSON Prompt Schema

Structured JSON prompts enable consistent, reproducible image generation with precise control over composition, lighting, and style.

### 4 Template Variants

#### 1. Editorial Template

Professional editorial photography with clean composition and natural lighting.

```json
{
  "template": "editorial",
  "subject": {
    "primary": "professional woman in business attire",
    "secondary": "modern office environment",
    "details": "confident expression, direct eye contact"
  },
  "composition": {
    "shot_type": "medium shot",
    "angle": "eye level",
    "rule_of_thirds": true,
    "negative_space": "right side for text overlay"
  },
  "lighting": {
    "type": "natural window light",
    "direction": "45-degree side lighting",
    "mood": "bright and professional",
    "shadows": "soft"
  },
  "color": {
    "palette": "warm neutrals",
    "hex_codes": ["#F5F5DC", "#D2B48C", "#8B7355"],
    "saturation": "moderate",
    "contrast": "medium-high"
  },
  "camera": {
    "focal_length": "85mm",
    "aperture": "f/2.8",
    "depth_of_field": "shallow",
    "sensor": "full frame"
  },
  "texture": {
    "skin": "natural with subtle retouching",
    "fabric": "crisp cotton, visible weave",
    "background": "soft bokeh"
  },
  "technical": {
    "resolution": "4K",
    "aspect_ratio": "16:9",
    "format": "PNG",
    "style": "photorealistic"
  }
}
```

#### 2. Environmental Template

Cinematic environmental shots with dramatic lighting and atmosphere.

```json
{
  "template": "environmental",
  "subject": {
    "primary": "mountain landscape at golden hour",
    "secondary": "winding road leading into distance",
    "details": "mist in valleys, snow-capped peaks"
  },
  "composition": {
    "shot_type": "wide shot",
    "angle": "slightly elevated",
    "leading_lines": "road curves from foreground to background",
    "depth_layers": ["foreground rocks", "midground valley", "background mountains"]
  },
  "lighting": {
    "type": "golden hour",
    "direction": "backlit with rim lighting",
    "mood": "epic and cinematic",
    "shadows": "long and dramatic",
    "highlights": "warm glow on peaks"
  },
  "color": {
    "palette": "warm golden tones with cool shadows",
    "hex_codes": ["#FFA500", "#FF8C00", "#4682B4", "#2F4F4F"],
    "saturation": "high",
    "contrast": "high"
  },
  "camera": {
    "focal_length": "24mm",
    "aperture": "f/11",
    "depth_of_field": "deep focus",
    "sensor": "full frame"
  },
  "texture": {
    "terrain": "rocky with visible detail",
    "vegetation": "sparse alpine grass",
    "atmosphere": "light haze and god rays"
  },
  "technical": {
    "resolution": "8K",
    "aspect_ratio": "16:9",
    "format": "PNG",
    "style": "cinematic realism",
    "camera_model": "ARRI Alexa LF"
  }
}
```

#### 3. Magazine Cover Template

Bold, attention-grabbing magazine cover style with strong visual hierarchy.

```json
{
  "template": "magazine_cover",
  "subject": {
    "primary": "confident entrepreneur in bold color",
    "secondary": "minimal background",
    "details": "direct gaze, power pose, statement accessory"
  },
  "composition": {
    "shot_type": "medium close-up",
    "angle": "slightly below eye level (power angle)",
    "rule_of_thirds": false,
    "centered": true,
    "negative_space": "top and sides for text"
  },
  "lighting": {
    "type": "studio lighting",
    "direction": "three-point lighting",
    "mood": "bold and confident",
    "shadows": "defined but not harsh",
    "rim_light": "strong separation from background"
  },
  "color": {
    "palette": "bold primary colors",
    "hex_codes": ["#FF0000", "#000000", "#FFFFFF"],
    "saturation": "very high",
    "contrast": "very high"
  },
  "camera": {
    "focal_length": "70mm",
    "aperture": "f/4",
    "depth_of_field": "moderate",
    "sensor": "medium format"
  },
  "texture": {
    "skin": "polished editorial retouching",
    "fabric": "high-end materials with sheen",
    "background": "solid color or subtle gradient"
  },
  "technical": {
    "resolution": "4K",
    "aspect_ratio": "3:4",
    "format": "PNG",
    "style": "high-fashion editorial"
  }
}
```

#### 4. Street Photography Template

Authentic, candid street photography with natural moments and urban environments.

```json
{
  "template": "street_photography",
  "subject": {
    "primary": "person walking through urban environment",
    "secondary": "city street with architecture",
    "details": "natural expression, mid-stride, unposed"
  },
  "composition": {
    "shot_type": "full shot",
    "angle": "eye level",
    "rule_of_thirds": true,
    "layers": ["foreground pedestrians", "subject", "background architecture"]
  },
  "lighting": {
    "type": "natural daylight",
    "direction": "overhead with building shadows",
    "mood": "authentic and gritty",
    "shadows": "hard urban shadows",
    "highlights": "bright patches of sunlight"
  },
  "color": {
    "palette": "desaturated urban tones",
    "hex_codes": ["#708090", "#A9A9A9", "#2F4F4F", "#D2691E"],
    "saturation": "low to moderate",
    "contrast": "medium"
  },
  "camera": {
    "focal_length": "35mm",
    "aperture": "f/5.6",
    "depth_of_field": "moderate",
    "sensor": "full frame"
  },
  "texture": {
    "pavement": "worn concrete with visible texture",
    "walls": "weathered brick or painted surfaces",
    "clothing": "everyday fabrics, natural wear"
  },
  "technical": {
    "resolution": "4K",
    "aspect_ratio": "3:2",
    "format": "PNG",
    "style": "documentary realism",
    "grain": "subtle film grain"
  }
}
```

## Style Library System

Save working JSON templates as named styles for reuse across projects. Swap only the subject/concept while maintaining consistent aesthetic.

### Creating a Style Library

1. **Generate and test** a JSON prompt until you achieve the desired look
2. **Save as named template** in your style library (e.g., `brand_editorial.json`, `product_hero.json`)
3. **Categorize by aesthetic** (e.g., `editorial/`, `cinematic/`, `product/`, `social/`)
4. **Reuse with subject swap** for consistent brand identity across all outputs

### Style Library Structure

```text
style-library/
├── editorial/
│   ├── brand_editorial.json          # Primary brand editorial style
│   ├── lifestyle_editorial.json      # Lifestyle content style
│   └── interview_editorial.json      # Interview/profile style
├── cinematic/
│   ├── hero_cinematic.json           # Hero shots and key visuals
│   ├── environmental_cinematic.json  # Landscape and environment
│   └── action_cinematic.json         # Dynamic action shots
├── product/
│   ├── product_hero.json             # Main product photography
│   ├── product_lifestyle.json        # Product in use
│   └── product_detail.json           # Close-up detail shots
└── social/
    ├── instagram_feed.json           # Instagram feed style
    ├── instagram_story.json          # Instagram story style
    └── youtube_thumbnail.json        # YouTube thumbnail style
```

### Subject Swap Pattern

```json
// Original template (saved in style library)
{
  "template": "editorial",
  "subject": {
    "primary": "{{SUBJECT_PRIMARY}}",
    "secondary": "{{SUBJECT_SECONDARY}}",
    "details": "{{SUBJECT_DETAILS}}"
  },
  // ... rest of template stays constant
}

// Reuse with new subject
{
  "template": "editorial",
  "subject": {
    "primary": "tech entrepreneur with laptop",
    "secondary": "modern co-working space",
    "details": "focused expression, typing on keyboard"
  },
  // ... rest of template unchanged
}
```

### Brand Identity Constants

Define brand-specific constants that remain consistent across all style templates:

```json
{
  "brand_constants": {
    "color_palette": {
      "primary": "#FF6B35",
      "secondary": "#004E89",
      "accent": "#F7B801",
      "neutral": ["#F5F5F5", "#333333"]
    },
    "lighting_mood": "bright and optimistic",
    "post_processing": {
      "contrast": "medium-high",
      "saturation": "moderate",
      "sharpness": "crisp",
      "vignette": "subtle"
    },
    "camera_preference": "full frame, 50-85mm range",
    "texture_style": "natural with subtle enhancement"
  }
}
```

## Thumbnail Factory Pattern

Generate consistent thumbnails at scale by combining style templates with topic concepts.

### Formula

```text
Style Template + Topic Concept = Consistent Thumbnail
```

### Thumbnail Requirements

| Platform | Aspect Ratio | Resolution | Text Readability | Face Prominence | Contrast |
|----------|-------------|------------|------------------|-----------------|----------|
| YouTube | 16:9 | 1280x720 (min) | Large, bold text | 30-40% of frame | High |
| Blog | 16:9 or 3:2 | 1200x630 | Medium text | Optional | Medium-high |
| Social (IG) | 1:1 or 4:5 | 1080x1080 | Minimal text | High | Very high |
| Social (X) | 16:9 | 1200x675 | Short text | Optional | High |

### Thumbnail JSON Template

```json
{
  "template": "youtube_thumbnail",
  "subject": {
    "primary": "{{TOPIC_VISUAL}}",
    "secondary": "{{CONTEXT_ELEMENT}}",
    "emotion": "{{TARGET_EMOTION}}"
  },
  "composition": {
    "shot_type": "close-up or medium close-up",
    "angle": "eye level or slightly below",
    "face_prominence": "30-40% of frame",
    "text_space": "left or right third",
    "visual_hierarchy": ["face/subject", "text overlay", "background"]
  },
  "lighting": {
    "type": "high-key studio lighting",
    "direction": "front lighting with rim light",
    "mood": "energetic and attention-grabbing",
    "shadows": "minimal"
  },
  "color": {
    "palette": "high-contrast complementary colors",
    "hex_codes": ["#FF0000", "#00FF00", "#0000FF", "#FFFF00"],
    "saturation": "very high",
    "contrast": "very high"
  },
  "camera": {
    "focal_length": "85mm",
    "aperture": "f/2.8",
    "depth_of_field": "shallow (subject sharp, background blur)"
  },
  "technical": {
    "resolution": "1280x720",
    "aspect_ratio": "16:9",
    "format": "PNG",
    "style": "bold and eye-catching",
    "text_overlay_space": true
  }
}
```

### Thumbnail Variant Generation

Generate 5-10 variants per topic before committing (see `content/optimization.md` for A/B testing).

```bash
# Generate thumbnail variants
for i in {1..10}; do
  # Modify emotion, angle, or color palette
  generate_thumbnail --template youtube_thumbnail \
    --subject "{{TOPIC}}" \
    --emotion "{{EMOTION_$i}}" \
    --seed "$((1000 + i))"
done
```

### Thumbnail Scoring Criteria

| Criterion | Weight | Evaluation |
|-----------|--------|------------|
| Text readability | 30% | Can you read text at 320px width? |
| Face prominence | 25% | Is face 30-40% of frame with clear emotion? |
| Contrast | 20% | Does it stand out in a grid of thumbnails? |
| Emotion clarity | 15% | Is the emotion immediately recognizable? |
| Brand consistency | 10% | Does it match brand color palette and style? |

## Annotated Frame-to-Video Workflow

Generate a static image, annotate with motion indicators, then feed to video model for animation.

### Workflow Steps

1. **Generate base image** using Nanobanana Pro or Midjourney
2. **Annotate with motion indicators**:
   - Arrows showing camera movement direction
   - Labels indicating object motion ("car moves left to right")
   - Timing markers ("0-2s: zoom in, 2-4s: pan right")
3. **Feed annotated image to video model** (Sora 2 or Veo 3.1)
4. **Video model interprets annotations** and generates motion

### Annotation Schema

```json
{
  "base_image": "path/to/generated_image.png",
  "annotations": [
    {
      "type": "camera_movement",
      "direction": "zoom in",
      "start_time": "0s",
      "end_time": "2s",
      "indicator": "arrow from edge to center"
    },
    {
      "type": "object_motion",
      "object": "car",
      "direction": "left to right",
      "speed": "moderate",
      "start_time": "0s",
      "end_time": "4s",
      "indicator": "arrow along path"
    },
    {
      "type": "label",
      "text": "Camera: slow zoom in",
      "position": "top-left",
      "color": "#FF0000"
    }
  ]
}
```

### Annotation Tools

- **Manual**: Photoshop, GIMP, Figma (add arrows and text overlays)
- **Programmatic**: Python + PIL/OpenCV (draw arrows and text)
- **AI-assisted**: Use vision model to suggest motion paths, then annotate

### Example Annotated Frame

```text
[Image: Mountain landscape]
Annotations:
- Red arrow from bottom to top: "Camera: crane up"
- Blue arrow left to right: "Clouds: drift right"
- Label top-left: "0-3s: slow reveal"
- Label bottom-right: "3-5s: hold on peak"
```

## Shotdeck Reference Library Workflow

Reverse-engineer cinematic references to extract reproducible prompts.

### Workflow

1. **Find cinematic reference** on Shotdeck (shotdeck.com) or similar
2. **Feed reference image to Gemini** (vision model)
3. **Prompt Gemini**: "Analyze this image and extract: composition (shot type, angle, framing), lighting (type, direction, mood, color temperature), color grading (palette, saturation, contrast), camera settings (focal length, aperture, depth of field), and texture descriptions (surfaces, materials, atmosphere). Output as a structured prompt for AI image generation."
4. **Gemini outputs structured prompt** with all technical details
5. **Use prompt with Nanobanana Pro or Midjourney** to recreate the look

### Gemini Reverse-Engineering Prompt

```text
Analyze this cinematic reference image and extract the following details for AI image generation:

1. **Composition**:
   - Shot type (ECU, CU, MCU, MS, MWS, WS, EWS)
   - Camera angle (eye level, high angle, low angle, Dutch angle)
   - Framing (rule of thirds, centered, symmetrical, asymmetrical)
   - Depth layers (foreground, midground, background elements)

2. **Lighting**:
   - Type (natural, studio, practical, mixed)
   - Direction (front, side, back, top, bottom)
   - Mood (bright, dark, moody, dramatic, soft)
   - Color temperature (warm, cool, neutral)
   - Shadow quality (hard, soft, absent)

3. **Color Grading**:
   - Dominant colors (list hex codes if possible)
   - Color palette (complementary, analogous, monochromatic)
   - Saturation level (low, moderate, high, very high)
   - Contrast level (low, medium, high, very high)

4. **Camera Settings**:
   - Estimated focal length (wide, normal, telephoto)
   - Estimated aperture (shallow DOF, moderate, deep focus)
   - Depth of field description

5. **Texture & Atmosphere**:
   - Surface textures (skin, fabric, walls, floors)
   - Atmospheric effects (haze, fog, dust, god rays)
   - Material properties (matte, glossy, reflective)

Output as a structured JSON prompt compatible with Nanobanana Pro format.
```

### Example Output

```json
{
  "reference": "Blade Runner 2049 - Officer K apartment scene",
  "composition": {
    "shot_type": "wide shot",
    "angle": "eye level",
    "framing": "centered with symmetrical architecture",
    "depth_layers": ["foreground window", "midground figure", "background cityscape"]
  },
  "lighting": {
    "type": "mixed (practical window light + neon signs)",
    "direction": "side lighting from window",
    "mood": "dark and moody with neon accents",
    "color_temperature": "cool blue with warm orange accents",
    "shadows": "deep shadows with high contrast"
  },
  "color_grading": {
    "palette": "cyberpunk (blue-orange complementary)",
    "hex_codes": ["#FF6B35", "#004E89", "#1A1A1A", "#F7B801"],
    "saturation": "moderate with neon highlights",
    "contrast": "very high"
  },
  "camera": {
    "focal_length": "35mm",
    "aperture": "f/2.8",
    "depth_of_field": "moderate (figure sharp, background slightly soft)"
  },
  "texture": {
    "walls": "concrete with visible texture and wear",
    "window": "rain-streaked glass with neon reflections",
    "atmosphere": "light haze with volumetric light rays"
  }
}
```

## Hex Color Code Precision

Use exact hex codes in prompts for consistent brand colors across all outputs.

### Brand Color Palette Template

```json
{
  "brand_colors": {
    "primary": {
      "name": "Brand Orange",
      "hex": "#FF6B35",
      "usage": "Primary CTAs, headlines, key elements"
    },
    "secondary": {
      "name": "Deep Blue",
      "hex": "#004E89",
      "usage": "Backgrounds, supporting elements"
    },
    "accent": {
      "name": "Golden Yellow",
      "hex": "#F7B801",
      "usage": "Highlights, attention-grabbing details"
    },
    "neutrals": [
      {"name": "Off-White", "hex": "#F5F5F5", "usage": "Backgrounds, text areas"},
      {"name": "Charcoal", "hex": "#333333", "usage": "Text, dark elements"}
    ]
  }
}
```

### Color Prompt Integration

```json
{
  "color": {
    "palette": "brand colors",
    "hex_codes": ["#FF6B35", "#004E89", "#F7B801", "#F5F5F5"],
    "distribution": {
      "#FF6B35": "30% (primary subject)",
      "#004E89": "40% (background)",
      "#F7B801": "10% (accents)",
      "#F5F5F5": "20% (highlights)"
    },
    "saturation": "high for brand colors, moderate for neutrals",
    "contrast": "high between primary and background"
  }
}
```

## Camera Settings in Prompts

Include camera settings for photorealistic results and consistent technical quality.

### Camera Settings Reference

| Setting | Options | Effect |
|---------|---------|--------|
| **Focal Length** | 14-24mm (ultra-wide), 24-35mm (wide), 50mm (normal), 85-135mm (portrait), 200mm+ (telephoto) | Field of view, perspective distortion |
| **Aperture** | f/1.4-f/2.8 (shallow DOF), f/4-f/8 (moderate), f/11-f/22 (deep focus) | Depth of field, background blur |
| **Sensor** | Full frame, APS-C, Medium format | Image quality, depth of field, low-light performance |
| **Camera Model** | RED Komodo 6K, ARRI Alexa LF, Sony Venice 8K, Canon EOS R5 | Overall look and feel |

### Camera Prompt Template

```json
{
  "camera": {
    "model": "ARRI Alexa LF",
    "sensor": "full frame",
    "focal_length": "85mm",
    "aperture": "f/2.8",
    "depth_of_field": "shallow (subject sharp, background bokeh)",
    "iso": "400",
    "shutter_speed": "1/125",
    "notes": "Cinematic look with natural skin tones"
  }
}
```

### 8K Camera Model Prompting

Append high-end camera models to prompts for cinematic quality:

```text
Shot on RED Komodo 6K
Shot on ARRI Alexa LF
Shot on Sony Venice 8K
Shot on Canon EOS C500 Mark II
```

## Texture Descriptions

Detailed texture descriptions improve realism and material accuracy.

### Texture Categories

| Category | Examples | Description Keywords |
|----------|----------|---------------------|
| **Skin** | Portrait, character | Natural, smooth, pores visible, subtle imperfections, healthy glow |
| **Fabric** | Clothing, textiles | Cotton weave, silk sheen, wool texture, denim grain, leather patina |
| **Surfaces** | Walls, floors | Concrete texture, wood grain, marble veining, metal brushed finish |
| **Nature** | Landscapes, plants | Rough bark, smooth stone, grass blades, water ripples, cloud wisps |
| **Atmosphere** | Air, light | Haze, fog, dust particles, god rays, volumetric light |

### Texture Prompt Template

```json
{
  "texture": {
    "skin": "natural with visible pores, subtle imperfections, healthy glow, no heavy retouching",
    "fabric": "crisp cotton shirt with visible weave, natural wrinkles, matte finish",
    "background": "weathered concrete wall with visible texture, subtle cracks, aged patina",
    "atmosphere": "light haze with dust particles visible in light rays, soft volumetric lighting"
  }
}
```

## Model Recency Arbitrage

Always use the latest-generation model. Older outputs get recognized as AI faster.

### Model Lifecycle

```text
New model released → 6-month window of "cutting edge" → Becomes recognizable as AI → Next model released
```

### Current Generation (2026)

| Category | Current Best | Previous Gen | Recognition Risk |
|----------|-------------|--------------|------------------|
| **Structured JSON** | Nanobanana Pro | Midjourney v5 | Low (new) |
| **General** | Midjourney v6 | Midjourney v5 | Low (current) |
| **Characters** | Freepik + Seedream 4 | DALL-E 3 | Low (current) |
| **Refinement** | Seedream 4 | Topaz Gigapixel | Low (new) |

### Upgrade Strategy

1. **Monitor new releases** (follow AI image generation news)
2. **Test new models immediately** (first-mover advantage)
3. **Migrate style library** to new model within 30 days
4. **Deprecate old outputs** after 6 months (regenerate key assets)

## Integration

### Feeds Into

- `content/production/video.md` - Frame-to-video workflow, thumbnail generation
- `content/production/characters.md` - Character consistency, facial engineering
- `content/optimization.md` - Thumbnail A/B testing, variant generation

### Uses Data From

- `content/research.md` - Audience preferences, competitor visual analysis
- `content/story.md` - Visual storytelling, emotional cues
- `tools/vision/image-generation.md` - Tool details, API access

### Related

- `tools/vision/image-editing.md` - Post-processing, refinement
- `tools/vision/image-understanding.md` - Image analysis, quality scoring
- `tools/video/video-prompt-design.md` - Video prompt engineering (related techniques)

## See Also

- `tools/vision/image-generation.md` - Detailed tool documentation
- `content/production/video.md` - Video generation workflow
- `content/production/characters.md` - Character consistency
- `content/optimization.md` - A/B testing and variant generation
