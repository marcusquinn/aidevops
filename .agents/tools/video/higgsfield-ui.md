---
description: "Higgsfield UI Automator - Browser-based generation using subscription credits via Playwright"
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

# Higgsfield UI Automator

Browser-based automation for Higgsfield AI using Playwright. This subagent drives the Higgsfield web UI to generate images, videos, lipsync, and effects using **subscription credits** (which are only available through the UI, not the API).

## When to Use

Use this subagent instead of the API subagent (`higgsfield.md`) when:

- The user's subscription credits only apply to the UI
- You need access to UI-exclusive features (apps, effects, presets, mixed media)
- You want to use models available in the UI but not yet in the API
- The API key has no credits but the subscription does

## Quick Reference

```bash
# Setup (first time)
~/.aidevops/agents/scripts/higgsfield-helper.sh setup

# Login (opens browser, saves auth state)
~/.aidevops/agents/scripts/higgsfield-helper.sh login

# Generate image (with options)
~/.aidevops/agents/scripts/higgsfield-helper.sh image "A cyberpunk city" --model soul --aspect 16:9 --quality 2k

# Generate video (image-to-video)
~/.aidevops/agents/scripts/higgsfield-helper.sh video "Camera pans across landscape" --image-file photo.jpg

# Generate lipsync video
~/.aidevops/agents/scripts/higgsfield-helper.sh lipsync "Hello world!" --image-file face.jpg

# Use an app/effect
~/.aidevops/agents/scripts/higgsfield-helper.sh app face-swap --image-file photo.jpg

# Check credits and unlimited models
~/.aidevops/agents/scripts/higgsfield-helper.sh credits

# Download latest video from History
~/.aidevops/agents/scripts/higgsfield-helper.sh download --model video
```

## Architecture

```text
higgsfield-helper.sh (shell wrapper)
  └── higgsfield/playwright-automator.mjs (Playwright automation, ~2000 lines)
        ├── Persistent auth state (~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json)
        ├── Site discovery cache (~/.aidevops/.agent-workspace/work/higgsfield/routes-cache.json)
        ├── Credentials from ~/.config/aidevops/credentials.sh
        └── Downloads to ~/Downloads/ (descriptive filenames: hf_{model}_{quality}_{prompt}_{ts}.ext)
```

**Why Playwright direct?** Fastest browser automation (0.9s form fill), full API control, headless/headed modes, persistent auth via `storageState`. No wrapper overhead.

## Setup

### Prerequisites

- Node.js or Bun
- Playwright (`npm install playwright` or `bun install playwright`)
- Chromium browser (`npx playwright install chromium`)

### Credentials

Store in `~/.config/aidevops/credentials.sh`:

```bash
export HIGGSFIELD_USER="your-email"
export HIGGSFIELD_PASS="your-password"
```

### First Login

```bash
# Opens browser for initial login (may need manual 2FA/captcha)
~/.aidevops/agents/scripts/higgsfield-helper.sh login
```

Auth state is saved to `~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json` and reused for subsequent headless sessions.

## Commands

### Image Generation

```bash
# Basic image (defaults to Soul model)
higgsfield-helper.sh image "A serene mountain landscape at golden hour"

# With model selection
higgsfield-helper.sh image "Portrait photo" --model nano_banana
higgsfield-helper.sh image "Anime character" --model seedream
higgsfield-helper.sh image "Product photo" --model gpt

# With options
higgsfield-helper.sh image "Landscape" --aspect 16:9 --quality 2k --enhance
higgsfield-helper.sh image "Portrait" --aspect 9:16 --preset "Sunset beach" --batch 4

# Headed mode (see the browser)
higgsfield-helper.sh image "Cyberpunk city" --headed

# Custom output directory
higgsfield-helper.sh image "Product photo" --output ~/Projects/assets/
```

### Video Generation

Video results appear in the History tab. The automator polls History for new items and downloads via the asset dialog.

```bash
# Image-to-video (recommended flow)
higgsfield-helper.sh image "A serene mountain landscape at golden hour"
higgsfield-helper.sh video "Camera slowly zooms in" --image-file ~/Downloads/hf_*.png

# With model and options
higgsfield-helper.sh video "Epic pan" --image-file photo.jpg --model kling-2.6 --unlimited

# With timeout for long generations (default 5 min)
higgsfield-helper.sh video "Cinematic shot" --image-file photo.jpg --timeout 600000

# Download latest video from History
higgsfield-helper.sh download --model video
```

### Lipsync Generation

```bash
# Text-to-speech lipsync
higgsfield-helper.sh lipsync "Hello! Welcome to our channel." --image-file face.jpg

# With model selection
higgsfield-helper.sh lipsync "Breaking news today..." --image-file anchor.jpg --model "Wan 2.5 Speak"
```

### Apps and Effects

Higgsfield has 86+ apps for one-click content creation:

```bash
# Face swap
higgsfield-helper.sh app face-swap --image-file face.jpg

# 3D render
higgsfield-helper.sh app 3d-render --image-file product.jpg

# Comic book style
higgsfield-helper.sh app comic-book --image-file photo.jpg

# Sketch to real
higgsfield-helper.sh app sketch-to-real --image-file sketch.jpg
```

**Popular apps**: face-swap, 3d-render, comic-book, transitions, recast, skin-enhancer, angles, relight, shots, zooms, poster, sketch-to-real, renaissance, mugshot, character-swap, outfit-swap, click-to-ad, plushies, sticker-matchcut

### Account Management

```bash
# Check credits, plan, and unlimited models
higgsfield-helper.sh credits

# List recent generations
higgsfield-helper.sh assets

# Take screenshot of any page
higgsfield-helper.sh screenshot https://higgsfield.ai/image/soul

# Download latest generation
higgsfield-helper.sh download              # images (default)
higgsfield-helper.sh download --model video # videos from History
```

## Available Models (UI) - Complete Map

### Image Models

| Model | Slug | URL | Controls | Cost | Unlimited? |
|-------|------|-----|----------|------|------------|
| Higgsfield Soul | `soul` | `/image/soul` | aspect (9:16,3:4,2:3,1:1,4:3,16:9,3:2), quality (1.5k,2k), enhance, batch 1-4, presets/styles, CHARACTER | 2 credits | Yes (365) |
| Nano Banana | `nano_banana` | `/image/nano_banana` | batch 1-4, auto aspect | 1 credit | Yes (365) |
| Nano Banana Pro | `nano-banana-pro` | `/nano-banana-pro` | aspect, quality (1K), batch 1-4, Unlimited switch | 2 credits | Yes (365) |
| Seedream 4.0 | `seedream` | `/image/seedream` | mode (Basic), aspect, batch 1-4 | 1 credit | Yes (365) |
| Seedream 4.5 | `seedream-4.5` | `/seedream-4-5` | aspect, quality (2K), batch 1-4, Unlimited switch | 1 credit | Yes (365) |
| WAN 2.2 | `wan2` | `/image/wan2` | aspect, enhance | 1 credit | No |
| GPT Image | `gpt` | `/image/gpt` | aspect, quality (Mid), batch 1-4, presets | 2 credits | Yes (365) |
| Flux Kontext Max | `kontext` | `/image/kontext` | batch 1-4, auto aspect, enhance | 1.5 credits | Yes (365) |
| FLUX.2 Pro | `flux` | `/image/flux` | model selector | varies | Yes (365) |
| Kling O1 Image | `kling-o1` | `/image/kling_o1` | varies | varies | Yes (365) |

**Visual Styles/Presets** (Soul model): Categories include All, New, TikTok Core, Instagram Aesthetics, Camera Presets, Beauty, Mood, Surreal, Graphic Art. Examples: General, Sunset beach, CCTV, Nail Check, 0.5 Outfit, Sand, Giant Accessory, iPhone, Mt. Fuji, Bimbocore.

### Video Models

| Model | Resolution | Duration | Cost | Unlimited? |
|-------|-----------|----------|------|------------|
| Kling 3.0 (Exclusive) | 1080p | 3-15s | varies | No |
| Kling 2.6 | 1080p | 5-10s | 10 credits | Yes |
| Kling 2.5 Turbo | 1080p | 5-10s | varies | Yes |
| Seedance 1.5 Pro | 720p | 4-12s | varies | No |
| Grok Imagine | 720p | 1-15s | varies | No |
| Minimax Hailuo | varies | varies | varies | No |
| OpenAI Sora 2 | varies | varies | varies | No |
| Google Veo | varies | varies | varies | No |
| Wan | varies | varies | varies | No |

**Video controls**: Duration (5s, 10s), Aspect Ratio (Auto or from image), Sound/Audio toggle, Unlimited mode toggle, Prompt with Enhance on/off, 250+ presets for camera control/framing/VFX.

### Lipsync Models

| Model | Resolution | Duration | Cost |
|-------|-----------|----------|------|
| Kling 2.6 Lipsync | 1080p | 10s | varies |
| Google Veo 3 | 720p | 8s | varies |
| Veo 3 Fast | 720p | 8s | varies |
| Wan 2.5 Speak | 480-1080p | 10s | 9 credits |
| Wan 2.5 Speak Fast | varies | varies | varies |
| Kling Avatars 2.0 | 720-1080p | up to 5min | varies |
| Higgsfield Speak 2.0 | 720p | 15s | varies |
| Infinite Talk | 480-720p | 15s | varies |
| Kling Lipsync | 720p | 15s | varies |
| Sync Lipsync 2 Pro | 4K | 15s | varies |

### Special Features (UI-only)

| Feature | URL Path | Description | Cost |
|---------|----------|-------------|------|
| Cinema Studio | `/cinema-studio` | Professional cinematic with real camera/lens simulation. Camera Setup, Bring It to Life, Camera Movements, Start & End Frame, Multiple Angles. Controls: aspect (16:9), quality (2K), camera/lens preset. | 20 credits (has free gens) |
| Vibe Motion | `/vibe-motion` | Sub-types: Infographics, Text Animation, Posters, Presentation, From Scratch. Styles: Minimal, Corporate, Fashion, Marketing. Duration: Auto/5/10/15/30s. | 8-60 credits |
| AI Influencer | `/ai-influencer-studio` | Character builder: Type (Human, Ant, Bee, Octopus, Alien, Elf, etc.), Gender, Ethnicity. | 30 free gens |
| Lipsync Studio | `/lipsync-studio` | Image + text/audio to talking video. 10 models available. | 9+ credits |
| Motion Control | `/create/motion-control` | Upload motion reference video (3-30s) + character image. Scene control, background source. | UNLIMITED (Kling) |
| Edit Video | `/create/edit` | Upload video + character image for editing. | varies |
| Upscale | `/upscale` | Upload media for AI upscaling. | varies |
| Character | `/character` | Create consistent characters from photos. | varies |
| Inpaint/Edit | various | 5 models for image editing/inpainting. | varies |
| Fashion Factory | `/fashion-factory` | AI fashion content. | varies |
| UGC Factory | `/ugc-factory` | User-generated content creation. | varies |
| Photodump Studio | `/photodump-studio` | Photo collection generation. | varies |
| Storyboard Generator | `/storyboard-generator` | Storyboard creation. | varies |

### Asset Dialog Actions

When viewing any generated image, the "Open in" menu provides:

- **Multishot** - Create multiple angles/shots
- **Inpaint** - Edit specific regions
- **Skin Enhancer** - Improve skin quality
- **Angles** - Generate different viewing angles
- **Relight** - Change lighting conditions
- **AI Stylist** - Apply style transformations
- **Upscale** - Increase resolution
- **Animate** - Send to video generation as start frame

## Unlimited Models Strategy

The account has 19 unlimited models (no credit cost). Always prefer these:

**Image (unlimited)**: Soul, Nano Banana, Nano Banana Pro, Seedream 4.0, GPT Image, Flux Kontext, FLUX.2 Pro, Kling O1 Image, Seedream 4.5, Reve, Z Image

**Video (unlimited)**: Kling 2.6, Kling 2.5 Turbo, Kling 2.6 Motion Control, Kling O1 Video, Kling O1 Video Edit

**Other (unlimited)**: Higgsfield Soul, Higgsfield Face Swap, Higgsfield Popcorn

Use `--unlimited` flag to restrict to unlimited models only.

**Unlimited model routing**: Models with "365" subscriptions use dedicated feature pages (e.g., `/nano-banana-pro`, `/seedream-4-5`) that have an "Unlimited" toggle switch. The automator automatically navigates to these pages and enables the switch. Standard `/image/` routes cost credits even for subscribed models.

## Download Filenames

All downloads use descriptive filenames:

```text
hf_{model}_{quality}_{preset}_{prompt-slug}_{timestamp}_{index}.{ext}
```

Example: `hf_higgsfield-soul_2k_sunset-beach_a-serene-mountain-landscape_20260209193400_1.png`

Metadata is extracted from the Asset showcase dialog before downloading.

## Production Pipeline

The `pipeline` command chains image generation, video animation, lipsync, and ffmpeg assembly into a single workflow. Video generation uses **parallel submission** -- all scene videos are submitted to Higgsfield at once, then polled simultaneously, cutting total time from N*4min to ~4min regardless of scene count.

### Brief JSON Format

```json
{
  "title": "Product Demo Short",
  "character": {
    "description": "Young woman, brown hair, warm smile, studio lighting",
    "image": "/path/to/face.png"
  },
  "scenes": [
    {
      "prompt": "Close-up of character holding product, warm lighting, shallow DOF",
      "duration": 5,
      "dialogue": "Check this out! It changed everything."
    },
    {
      "prompt": "Wide shot of character in modern kitchen, natural light",
      "duration": 5,
      "dialogue": "I use it every single day."
    }
  ],
  "imagePrompts": [
    "Photorealistic product shot, warm lighting, shallow DOF, 9:16",
    "Wide shot modern kitchen, natural light, clean aesthetic, 9:16"
  ],
  "imageModel": "nano-banana-pro",
  "videoModel": "kling-2.6",
  "aspect": "9:16",
  "captions": [
    { "text": "Check this out!", "startFrame": 0, "endFrame": 60 },
    { "text": "It changed everything.", "startFrame": 60, "endFrame": 150 }
  ],
  "transitionStyle": "fade",
  "transitionDuration": 15,
  "music": "/path/to/background.mp3"
}
```

**`imagePrompts[]`** (optional): Separate prompts for start frame image generation. When provided, `imagePrompts[i]` is used for image generation while `scenes[i].prompt` is used for video animation. This allows optimizing each prompt for its purpose (static composition vs motion).

**`captions[]`** (optional): Caption entries for Remotion overlay. Each entry has `text`, `startFrame`, `endFrame`, and optional `style` (bold-white, minimal, impact, typewriter, highlight).

**`transitionStyle`** (optional): Scene transition type for Remotion (fade, slide, wipe). Default: fade.

**`transitionDuration`** (optional): Transition duration in frames. Default: 15.

### Pipeline Steps

1. **Character image** - Generate or use provided character face
2. **Scene images** - Generate one image per scene (uses `imagePrompts[]` if provided, else `scenes[].prompt`)
3. **Video animation** - Submit ALL scene videos in parallel, poll for all simultaneously
   - 3a: Submit jobs (upload start frame + prompt + click Generate for each scene, ~30s each)
   - 3b: Poll History tab for all submitted prompts at once
   - 3c: Download completed videos via API interception or direct fetch (CloudFront, 1080p)
4. **Lipsync** - Add dialogue to scenes that have it
5. **Assembly** - Remotion render with captions + transitions (falls back to ffmpeg concat)

### Remotion Post-Production

When Remotion is installed (`cd .agents/scripts/higgsfield/remotion && npm install`), the pipeline uses it for assembly instead of ffmpeg. Remotion provides:

- **Animated captions** with 5 preset styles (bold-white, minimal, impact, typewriter, highlight)
- **Scene transitions** (fade, slide, wipe) via `@remotion/transitions`
- **Title cards** and static graphics between scenes
- **Dynamic duration** computed from actual video files via `calculateMetadata`
- **Programmatic rendering** at any resolution (default: 1080x1920 for 9:16)

```bash
# Install Remotion (one-time)
cd ~/.aidevops/agents/scripts/higgsfield/remotion && npm install

# Standalone render (outside pipeline)
node render.mjs --props brief-props.json --output final.mp4
```

Files in `remotion/`: Root.tsx (composition registry), FullVideo.tsx (main composition), CaptionOverlay.tsx (animated captions), SceneVideo.tsx (video embed), SceneGraphic.tsx (title cards), styles.ts (caption presets), types.ts (TypeScript types).

### Pipeline Examples

```bash
# From a brief file
higgsfield-helper.sh pipeline --brief brief.json

# Quick single-scene pipeline
higgsfield-helper.sh pipeline "Person reviews product" --character-image face.png --dialogue "This is amazing!"

# Multi-scene with output directory
higgsfield-helper.sh pipeline --brief scenes.json --output ~/Projects/shorts/
```

Output goes to `~/Downloads/pipeline-{timestamp}/` with all intermediate files and a `pipeline-state.json` manifest.

### Performance

| Scenes | Sequential | Parallel | Savings |
|--------|-----------|----------|---------|
| 1 | ~4 min | ~4 min | -- |
| 2 | ~8 min | ~4 min | 50% |
| 5 | ~20 min | ~4 min | 80% |
| 10 | ~40 min | ~5 min | 87% |

Video generation time is dominated by Higgsfield's server-side processing (~3-4 min per video). Parallel submission means all videos process concurrently.

## Seed Bracketing

Based on the technique from "How I Cut AI Video Costs By 60%". Test a range of seeds with the same prompt to find which produce the best results, then reuse winning seeds.

### How It Works

1. Test 10-11 seeds with the same prompt
2. Score each result on composition, quality, style match
3. Pick 2-3 winners as foundations
4. Use winning seeds for consistent results

### Recommended Seed Ranges

| Content Type | Range | Notes |
|-------------|-------|-------|
| People/talking heads | 1000-1999 | Good for faces, expressions, close-ups |
| Action/movement | 2000-2999 | Dynamic scenes, camera movement |
| Landscape/establishing | 3000-3999 | Environments, wide shots, cinematic |
| Product demos | 4000-4999 | Clean commercial look |

### Seed Bracket Examples

```bash
# Test seeds 1000-1010 for a portrait prompt
higgsfield-helper.sh seed-bracket "Elegant woman, golden hour lighting, cinematic" --seed-range 1000-1010

# Test specific seeds
higgsfield-helper.sh seed-bracket "Product on marble table" --seed-range "4000,4003,4008,4015"

# With model selection
higgsfield-helper.sh seed-bracket "Cyberpunk street" --seed-range 2000-2010 --model nano_banana_pro
```

Results saved to `~/Downloads/seed-bracket-{timestamp}/` with `bracket-results.json` manifest.

## CLI Options Reference

```text
--prompt, -p       Text prompt for generation
--model, -m        Model slug (soul, nano_banana, seedream, kling-2.6, gpt, kontext, flux)
--aspect, -a       Aspect ratio (16:9, 9:16, 1:1, 3:4, 4:3, 2:3, 3:2)
--quality, -q      Quality setting (1K, 1.5K, 2K, 4K)
--output, -o       Output directory or file path
--headed           Run browser in headed mode (visible)
--headless         Run browser in headless mode (default)
--duration, -d     Video duration in seconds (5, 10, 15)
--image-file       Path to image file for upload
--image-url, -i    URL of image for image-to-video
--wait             Wait for generation to complete
--timeout          Timeout in milliseconds
--effect           App/effect slug (e.g., face-swap, 3d-render)
--enhance          Enable prompt enhancement
--no-enhance       Disable prompt enhancement
--sound            Enable sound/audio for video
--no-sound         Disable sound/audio
--batch, -b        Number of images to generate (1-4)
--unlimited        Prefer unlimited models only
--preset, -s       Style preset name (e.g., "Sunset beach", "CCTV")
--seed             Seed number for reproducible generation
--seed-range       Seed range for bracketing (e.g., "1000-1010")
--brief            Path to pipeline brief JSON file
--character-image  Character face image for pipeline
--dialogue         Dialogue text for lipsync in pipeline
--scenes           Number of scenes to generate
```

## Prompt Engineering Tips

### Images

```text
Good: "A professional photograph of a golden retriever puppy playing in a sunlit garden"
Better: "Professional pet photography, golden retriever puppy, 3 months old, playing with
a red ball in a lush green garden, golden hour lighting, shallow depth of field, Canon EOS
R5, 85mm lens, bokeh background"
```

### Videos

```text
Good: "The camera slowly pans across the scene"
Better: "Smooth cinematic camera pan from left to right, golden hour lighting, gentle wind
rustling through leaves, shallow depth of field, 24fps film grain"
```

### Quality Modifiers

- Photorealistic: "photorealistic, 8k, highly detailed, professional photography"
- Cinematic: "cinematic lighting, anamorphic lens, film grain, color graded"
- Artistic: "digital art, concept art, trending on artstation, vibrant colors"
- Portrait: "studio lighting, shallow depth of field, bokeh, 85mm lens"

## Troubleshooting

### Auth Issues

```bash
# Re-login (clears old state)
rm ~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json
higgsfield-helper.sh login
```

### Generation Not Starting

1. Check credits: `higgsfield-helper.sh credits`
2. Try headed mode: `higgsfield-helper.sh image "test" --headed`
3. Check screenshots in `~/.aidevops/.agent-workspace/work/higgsfield/`

### Video Download Issues

Video results appear in the History tab, not as inline elements. The automator uses two strategies: API response interception (primary) and direct API fetch (fallback). If download fails:

1. Try downloading manually: `higgsfield-helper.sh download --model video`
2. Check `video-result.png` screenshot for the current state
3. The video may still be processing -- try again after a few minutes
4. The direct fetch fallback calls `fnf.higgsfield.ai/project?job_set_type=image2video` using the page's auth cookies

### Browser Not Found

```bash
npx playwright install chromium
```

## Debug Screenshots

All operations save debug screenshots to `~/.aidevops/.agent-workspace/work/higgsfield/`:

- `login-debug.png` - Login page state
- `image-page.png` - Image generation page
- `generation-result.png` - After image generation
- `video-page.png` - Video generation page
- `video-generate-clicked.png` - After clicking Generate for video
- `video-result.png` - Video generation result
- `video-download-result.png` - After video download attempt
- `lipsync-page.png` - Lipsync studio page
- `subscription.png` - Account/credits page
- `error.png` - Error state

## Headed vs Headless

| Mode | Flag | Use Case |
|------|------|----------|
| Headless | `--headless` (default) | Automated pipelines, CI/CD |
| Headed | `--headed` | Debugging, first login, manual intervention |

**First login must be headed** to handle potential CAPTCHAs or 2FA. Subsequent sessions can be headless using saved auth state.

## Related

- `higgsfield.md` - API-based generation (requires API credits)
- `tools/browser/browser-automation.md` - Browser tool selection guide
- `tools/browser/playwright.md` - Playwright reference
- `tools/video/video-prompt-design.md` - Video prompt engineering
