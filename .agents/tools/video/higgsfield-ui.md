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

Browser-based automation for Higgsfield AI using Playwright. Drives the Higgsfield web UI to generate images, videos, lipsync, and effects using **subscription credits** (only available through the UI, not the API).

**Automation Coverage**: Full UI coverage — Image generation (10/10 models), Video creation (4/4 workflows), Cinema Studio, Motion Control, Video Edit, Edit/Inpaint (5 models), Upscale, Lipsync (11 models), Apps (38+ via generic handler), Asset Library + Asset Chaining (9 actions), Mixed Media Presets (32), Motion/VFX Presets (150+), Vibe Motion (5 sub-types), Storyboard Generator, AI Influencer Studio, Character profiles, Feature pages, Pipeline with Remotion post-production, Seed Bracketing. **27 CLI commands total.**

## When to Use

Use instead of the API subagent (`higgsfield.md`) when: subscription credits only apply to the UI, you need UI-exclusive features (apps, effects, presets, mixed media), models are available in UI but not API, or the API key has no credits but the subscription does.

## Quick Reference

```bash
~/.aidevops/agents/scripts/higgsfield-helper.sh setup
~/.aidevops/agents/scripts/higgsfield-helper.sh login

higgsfield-helper.sh image "A cyberpunk city" --model soul --aspect 16:9 --quality 2k
higgsfield-helper.sh video "Camera pans across landscape" --image-file photo.jpg
higgsfield-helper.sh lipsync "Hello world!" --image-file face.jpg
higgsfield-helper.sh app face-swap --image-file photo.jpg
higgsfield-helper.sh cinema-studio "Epic landscape" --tab image --camera "Dolly Zoom"
higgsfield-helper.sh motion-control --video-file dance.mp4 --image-file character.jpg
higgsfield-helper.sh edit "Replace background with beach" --image-file photo.jpg -m soul_inpaint
higgsfield-helper.sh upscale --image-file low-res.jpg
higgsfield-helper.sh manage-assets --asset-action list --filter video
higgsfield-helper.sh credits
higgsfield-helper.sh download --model video
```

## Architecture

```text
higgsfield-helper.sh (shell wrapper)
  └── higgsfield/playwright-automator.mjs (~4900 lines)
        ├── Persistent auth state (~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json)
        ├── Site discovery cache (~/.aidevops/.agent-workspace/work/higgsfield/routes-cache.json)
        ├── Credentials from ~/.config/aidevops/credentials.sh
        ├── Downloads to ~/Downloads/higgsfield/ (interactive) or .agent-workspace (headless)
        ├── Descriptive filenames: hf_{model}_{quality}_{prompt}_{ts}.ext
        ├── JSON sidecar metadata (.json alongside each download)
        └── SHA-256 dedup index (.dedup-index.json per output dir)
```

## Setup

**Prerequisites**: Node.js or Bun, Playwright (`npm install playwright`), Chromium (`npx playwright install chromium`).

**Credentials** in `~/.config/aidevops/credentials.sh`:

```bash
export HIGGSFIELD_USER="your-email"
export HIGGSFIELD_PASS="your-password"
```

**First login** (headed — may need manual 2FA/captcha):

```bash
higgsfield-helper.sh login
# Auth state saved to ~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json
```

## Commands

### Image Generation

```bash
higgsfield-helper.sh image "A serene mountain landscape at golden hour"
higgsfield-helper.sh image "Portrait photo" --model nano_banana
higgsfield-helper.sh image "Landscape" --aspect 16:9 --quality 2k --enhance
higgsfield-helper.sh image "Portrait" --aspect 9:16 --preset "Sunset beach" --batch 4
higgsfield-helper.sh image "Cyberpunk city" --headed
higgsfield-helper.sh image "Product photo" --output ~/Projects/assets/
```

### Video Generation

Video results appear in the History tab. The automator polls History for new items.

```bash
higgsfield-helper.sh image "A serene mountain landscape at golden hour"
higgsfield-helper.sh video "Camera slowly zooms in" --image-file ~/Downloads/hf_*.png
higgsfield-helper.sh video "Epic pan" --image-file photo.jpg --model kling-2.6 --unlimited
higgsfield-helper.sh video "Cinematic shot" --image-file photo.jpg --timeout 600000
higgsfield-helper.sh download --model video
```

### Lipsync Generation

```bash
higgsfield-helper.sh lipsync "Hello! Welcome to our channel." --image-file face.jpg
higgsfield-helper.sh lipsync "Breaking news today..." --image-file anchor.jpg --model "Wan 2.5 Speak"
```

### Apps and Effects

38+ apps for one-click content creation (visible on /apps page):

```bash
higgsfield-helper.sh app face-swap --image-file face.jpg
higgsfield-helper.sh app 3d-render --image-file product.jpg
higgsfield-helper.sh app comic-book --image-file photo.jpg
higgsfield-helper.sh app sketch-to-real --image-file sketch.jpg
```

**Popular apps**: face-swap, 3d-render, comic-book, transitions, recast, skin-enhancer, angles, relight, shots, zooms, poster, sketch-to-real, renaissance, mugshot, character-swap, outfit-swap, link-to-video-ad, plushies, sticker-matchcut, surrounded-by-animals

### Cinema Studio

Professional cinematic image/video with camera and lens simulation presets. Cost: 20 credits (has free generations).

```bash
higgsfield-helper.sh cinema-studio "Epic mountain landscape at golden hour" --tab image --camera "Dolly Zoom"
higgsfield-helper.sh cinema-studio "Dramatic reveal of ancient temple" --duration 10 --lens "Anamorphic"
higgsfield-helper.sh cinema-studio "Product hero shot" --tab image --quality 4K --aspect 16:9
```

### Motion Control

Animate a character image using a motion reference video. Cost: UNLIMITED with Kling.

```bash
higgsfield-helper.sh motion-control --video-file dance.mp4 --image-file character.jpg
higgsfield-helper.sh motion-control --motion-ref walk.mp4 --image-file person.jpg -p "Walking through park"
higgsfield-helper.sh motion-control --video-file ref.mp4 --image-file face.jpg --unlimited
```

### Edit/Inpaint

5 models: `soul_inpaint` (default), `nano_banana_pro_inpaint`, `banana_placement`, `canvas`, `multi`.

```bash
higgsfield-helper.sh edit "Replace background with tropical beach" --image-file photo.jpg
higgsfield-helper.sh edit "Place product on marble table" --image-file product.jpg -m banana_placement
higgsfield-helper.sh edit "Combine styles" --image-file base.jpg --image-file2 reference.jpg -m multi
```

### Upscale / Asset Library / Asset Chaining

```bash
higgsfield-helper.sh upscale --image-file low-res.jpg
higgsfield-helper.sh upscale --video-file clip.mp4

higgsfield-helper.sh manage-assets --asset-action list [--filter image|video|lipsync|upscaled|liked]
higgsfield-helper.sh manage-assets --asset-action download-latest --filter image
higgsfield-helper.sh manage-assets --asset-action download-all --limit 20

# Chain asset to another tool without re-uploading
higgsfield-helper.sh chain --chain-action animate --asset-index 0
higgsfield-helper.sh chain --chain-action inpaint -p "Replace background with sunset" --asset-index 0
higgsfield-helper.sh chain --chain-action upscale|relight|angles|shots|ai-stylist|skin-enhancer|multishot --asset-index 0
```

### Mixed Media / Motion/VFX Presets

```bash
higgsfield-helper.sh mixed-media --preset sketch|noir|layer|canvas|flash_comic|overexposed|paper|particles|hand_paint|toxic|vintage|comic|origami|marble|lava|ocean|magazine|modern|acid|tracking|ultraviolet|glitch|neon|watercolor|blueprint|thermal|xray|infrared|hologram|pixelate|mosaic --image-file photo.jpg

higgsfield-helper.sh motion-preset                                    # List available presets
higgsfield-helper.sh motion-preset --preset dolly_zoom --image-file photo.jpg
```

### Video Edit / Storyboard / Vibe Motion / AI Influencer / Character

```bash
higgsfield-helper.sh video-edit --video-file clip.mp4 --image-file character.jpg -p "Character walks through scene"

higgsfield-helper.sh storyboard -p "A hero's journey through a cyberpunk city" --scenes 6
higgsfield-helper.sh storyboard -p "Product launch story" --scenes 4 --preset "Cinematic"

# Vibe Motion sub-types: infographics, text-animation, posters, presentation, from-scratch
higgsfield-helper.sh vibe-motion -p "Product launch announcement" --tab posters --preset Corporate
higgsfield-helper.sh vibe-motion -p "Q4 Revenue Growth 45%" --tab infographics --preset Minimal
# Styles: Minimal, Corporate, Fashion, Marketing. Duration: Auto/5/10/15/30s. Cost: 8-60 credits.

# AI Influencer (30 free gens). Types: Human, Ant, Bee, Octopus, Alien, Elf, etc.
higgsfield-helper.sh influencer --preset Human -p "Fashion influencer, warm smile, studio lighting"

# Character profiles for consistent generation
higgsfield-helper.sh character --image-file face.jpg -p "Sarah"
higgsfield-helper.sh character --image-file face1.jpg --image-file2 face2.jpg -p "Alex"
```

### Feature Pages

```bash
higgsfield-helper.sh feature --feature fashion-factory|ugc-factory|photodump-studio|camera-controls|effects --image-file photo.jpg
# Shorthand:
higgsfield-helper.sh fashion-factory --image-file outfit.jpg
higgsfield-helper.sh ugc-factory --image-file product.jpg
```

### Account Management

```bash
higgsfield-helper.sh credits    # Check credits, plan, and unlimited models
higgsfield-helper.sh assets     # List recent generations
higgsfield-helper.sh screenshot https://higgsfield.ai/image/soul
higgsfield-helper.sh download [--model video]
```

## Available Models (UI)

### Image Models

| Model | Slug | URL | Cost | Unlimited? |
|-------|------|-----|------|------------|
| Higgsfield Soul | `soul` | `/image/soul` | 2 credits | Yes (365) |
| Nano Banana | `nano_banana` | `/image/nano_banana` | 1 credit | Yes (365) |
| Nano Banana Pro | `nano-banana-pro` | `/nano-banana-pro` | 2 credits | Yes (365) |
| Seedream 4.0 | `seedream` | `/image/seedream` | 1 credit | Yes (365) |
| Seedream 4.5 | `seedream-4.5` | `/seedream-4-5` | 1 credit | Yes (365) |
| WAN 2.2 | `wan2` | `/image/wan2` | 1 credit | No |
| GPT Image | `gpt` | `/image/gpt` | 2 credits | Yes (365) |
| Flux Kontext Max | `kontext` | `/image/kontext` | 1.5 credits | Yes (365) |
| FLUX.2 Pro | `flux` | `/image/flux` | varies | Yes (365) |
| Kling O1 Image | `kling-o1` | `/image/kling_o1` | varies | Yes (365) |

**Visual Styles/Presets** (Soul model): All, New, TikTok Core, Instagram Aesthetics, Camera Presets, Beauty, Mood, Surreal, Graphic Art. Examples: General, Sunset beach, CCTV, Nail Check, 0.5 Outfit, Sand, Giant Accessory, iPhone, Mt. Fuji, Bimbocore.

### Video Models

| Model | Resolution | Duration | Cost | Unlimited? |
|-------|-----------|----------|------|------------|
| Kling 3.0 (Exclusive) | 1080p | 3-15s | varies | No |
| Kling 2.6 | 1080p | 5-10s | 10 credits | Yes |
| Kling 2.5 Turbo | 1080p | 5-10s | varies | Yes |
| Seedance 1.5 Pro | 720p | 4-12s | varies | No |
| Grok Imagine / Minimax Hailuo / OpenAI Sora 2 / Google Veo / Wan | varies | varies | varies | No |

### Lipsync Models (11 total)

Wan 2.5 Fast, Kling 2.6 Lipsync, Google Veo 3, Veo 3 Fast, Wan 2.5 Speak (9 credits), Wan 2.5 Speak Fast, Kling Avatars 2.0 (up to 5min), Higgsfield Speak 2.0, Infinite Talk, Kling Lipsync, Sync Lipsync 2 Pro (4K).

### Special Features (UI-only)

| Feature | URL Path | Cost |
|---------|----------|------|
| Cinema Studio | `/cinema-studio` | 20 credits (has free gens) |
| Vibe Motion | `/vibe-motion` | 8-60 credits |
| AI Influencer | `/ai-influencer-studio` | 30 free gens |
| Lipsync Studio | `/lipsync-studio` | 9+ credits |
| Motion Control | `/create/motion-control` | UNLIMITED (Kling) |
| Edit Video | `/create/edit` | varies |
| Upscale | `/upscale` | varies |
| Character | `/character` | varies |
| Fashion/UGC/Photodump/Storyboard | various | varies |

## Unlimited Models Strategy

The account has 19 unlimited models (no credit cost). The automator **auto-selects the best unlimited model** by default (`--prefer-unlimited`, on by default).

**Image models** (ranked by SOTA quality for product shots):

| Priority | Model | Slug |
|----------|-------|------|
| 1 | GPT Image | `gpt` |
| 2 | Seedream 4.5 | `seedream-4-5` |
| 3 | FLUX.2 Pro | `flux` |
| 4 | Flux Kontext | `kontext` |
| 5 | Reve | `reve` |
| 6 | Nano Banana Pro | `nano-banana-pro` |
| 7 | Soul | `soul` |
| 8-12 | Kling O1, Seedream 4.0, Nano Banana, Z Image, Popcorn | various |

**Video models** (ranked): Kling 2.6 (`kling-2.6`) → Kling O1 Video (`kling-o1`) → Kling 2.5 Turbo (`kling-2.5`).

**Other unlimited**: Kling O1 Video Edit, Kling 2.6 Motion Control, Face Swap.

**Unlimited model routing**: Models with "365" subscriptions use dedicated feature pages (e.g., `/nano-banana-pro`, `/seedream-4-5`) with an "Unlimited" toggle. Standard `/image/` routes cost credits even for subscribed models.

**Self-tests**: `node playwright-automator.mjs test` (44 tests).

## Output Organization

| Context | Default Output |
|---------|---------------|
| Interactive (TTY / `--headed`) | `~/Downloads/higgsfield/` |
| Headless / pipeline | `~/.aidevops/.agent-workspace/work/higgsfield/output/` |

Override with `--output`. Use `--project` for organized subdirectories (`{output}/{project}/images/`, `/videos/`, `/lipsync/`, etc.).

**Filenames**: `hf_{model}_{quality}_{preset}_{prompt-slug}_{timestamp}_{index}.{ext}`

**JSON sidecar**: Every download gets a `.json` companion with source, model, quality, preset, prompt, fileSize. Disable with `--no-sidecar`.

**Deduplication**: SHA-256 hash-based, tracked in `.dedup-index.json`. Disable with `--no-dedup`.

## Production Pipeline

The `pipeline` command chains image generation, video animation, lipsync, and ffmpeg assembly. Video generation uses **parallel submission** — all scene videos submitted at once, polled simultaneously (~4min regardless of scene count).

```bash
higgsfield-helper.sh pipeline --brief brief.json
higgsfield-helper.sh pipeline "Person reviews product" --character-image face.png --dialogue "This is amazing!"
higgsfield-helper.sh pipeline --brief scenes.json --output ~/Projects/shorts/
```

**Brief JSON format**:

```json
{
  "title": "Product Demo Short",
  "character": { "description": "Young woman, brown hair", "image": "/path/to/face.png" },
  "scenes": [
    { "prompt": "Close-up holding product", "duration": 5, "dialogue": "Check this out!" }
  ],
  "imagePrompts": ["Photorealistic product shot, 9:16"],
  "imageModel": "nano-banana-pro",
  "videoModel": "kling-2.6",
  "aspect": "9:16",
  "captions": [{ "text": "Check this out!", "startFrame": 0, "endFrame": 60 }],
  "transitionStyle": "fade",
  "transitionDuration": 15,
  "music": "/path/to/background.mp3"
}
```

**`imagePrompts[]`**: Separate prompts for start frame image generation (static composition vs motion). **`captions[]`**: Remotion overlay. Styles: bold-white, minimal, impact, typewriter, highlight.

**Pipeline steps**: Character image → Scene images → Video animation (parallel submit + poll) → Lipsync → Assembly (Remotion or ffmpeg fallback).

**Remotion post-production** (`cd .agents/scripts/higgsfield/remotion && npm install`): Animated captions (5 styles), scene transitions (fade/slide/wipe), title cards, dynamic duration, 1080x1920 default.

**Performance**: 5 scenes = ~4min (parallel) vs ~20min (sequential). 10 scenes = ~5min vs ~40min.

## Seed Bracketing

Test a range of seeds with the same prompt to find best results, then reuse winning seeds.

```bash
higgsfield-helper.sh seed-bracket "Elegant woman, golden hour lighting, cinematic" --seed-range 1000-1010
higgsfield-helper.sh seed-bracket "Product on marble table" --seed-range "4000,4003,4008,4015"
higgsfield-helper.sh seed-bracket "Cyberpunk street" --seed-range 2000-2010 --model nano_banana_pro
```

**Recommended seed ranges**: People/talking heads: 1000-1999 | Action/movement: 2000-2999 | Landscape/establishing: 3000-3999 | Product demos: 4000-4999.

## CLI Options Reference

```text
--prompt, -p       Text prompt
--model, -m        Model slug (soul, nano_banana, seedream, kling-2.6, gpt, kontext, flux)
--aspect, -a       Aspect ratio (16:9, 9:16, 1:1, 3:4, 4:3, 2:3, 3:2)
--quality, -q      Quality (1K, 1.5K, 2K, 4K)
--output, -o       Output directory
--headed/--headless  Browser mode (headless default)
--duration, -d     Video duration in seconds (5, 10, 15)
--image-file       Path to image file
--image-url, -i    URL of image
--image-file2      Second image file (multi-reference edit)
--video-file/--motion-ref  Path to video file (motion reference)
--wait/--timeout   Wait for completion / timeout in ms
--effect           App/effect slug (face-swap, 3d-render, etc.)
--enhance/--no-enhance  Prompt enhancement toggle
--sound/--no-sound  Audio toggle for video
--batch, -b        Number of images (1-4)
--prefer-unlimited/--no-prefer-unlimited  Unlimited model auto-selection
--preset, -s       Style preset name
--seed             Seed number
--seed-range       Seed range for bracketing (1000-1010 or "4000,4003,4008")
--brief            Path to pipeline brief JSON
--character-image  Character face image for pipeline
--dialogue         Dialogue text for lipsync in pipeline
--scenes           Number of scenes
--camera/--lens    Camera/lens preset for cinema-studio
--tab              Tab selection: "image" or "video"
--filter           Asset filter: image, video, lipsync, upscaled, liked
--asset-action     Asset action: list, download, download-latest, download-all
--asset-index      Index of specific asset (0-based)
--limit            Max assets to download
--chain-action     Chain action: animate, inpaint, upscale, relight, angles, shots, ai-stylist, skin-enhancer, multishot
--feature          Feature page: fashion-factory, ugc-factory, photodump-studio, camera-controls, effects
--subtype          Vibe Motion sub-type: infographics, text-animation, posters, presentation, from-scratch
--project          Project name for organized output dirs
--no-sidecar       Disable JSON sidecar metadata
--no-dedup         Disable SHA-256 duplicate detection
```

## Prompt Engineering Tips

**Images**: Add camera, lighting, lens, and technical details. Example: "Professional pet photography, golden retriever puppy, 3 months old, playing with a red ball, golden hour lighting, shallow depth of field, Canon EOS R5, 85mm lens, bokeh background"

**Videos**: Describe camera movement explicitly. Example: "Smooth cinematic camera pan from left to right, golden hour lighting, gentle wind rustling through leaves, shallow depth of field, 24fps film grain"

**Quality modifiers**: Photorealistic: "photorealistic, 8k, highly detailed, professional photography" | Cinematic: "cinematic lighting, anamorphic lens, film grain, color graded" | Portrait: "studio lighting, shallow depth of field, bokeh, 85mm lens"

## Troubleshooting

```bash
# Auth issues
rm ~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json
higgsfield-helper.sh login

# Generation not starting
higgsfield-helper.sh credits
higgsfield-helper.sh image "test" --headed  # Check in browser

# Video download issues — try manual download
higgsfield-helper.sh download --model video
# Direct fetch fallback: calls fnf.higgsfield.ai/project?job_set_type=image2video

# Browser not found
npx playwright install chromium
```

**Debug screenshots** saved to `~/.aidevops/.agent-workspace/work/higgsfield/`: login-debug.png, image-page.png, generation-result.png, video-page.png, video-result.png, lipsync-page.png, subscription.png, error.png.

**Headed vs Headless**: Use `--headed` for debugging, first login, or manual intervention. First login must be headed to handle CAPTCHAs or 2FA.

## Related

- `higgsfield.md` — API-based generation (requires API credits)
- `tools/browser/browser-automation.md` — Browser tool selection guide
- `tools/browser/playwright.md` — Playwright reference
- `tools/video/video-prompt-design.md` — Video prompt engineering
