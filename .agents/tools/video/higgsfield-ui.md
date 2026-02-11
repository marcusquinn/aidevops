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

**Automation Coverage**: Full UI coverage -- Image generation (10/10 models), Video creation (4/4 workflows), Cinema Studio, Motion Control, Video Edit, Edit/Inpaint (5 models), Upscale, Lipsync (11 models), Apps (38+ via generic handler), Asset Library + Asset Chaining (9 actions), Mixed Media Presets (32), Motion/VFX Presets (150+), Vibe Motion (5 sub-types), Storyboard Generator, AI Influencer Studio, Character profiles, Feature pages (Fashion Factory, UGC Factory, Photodump Studio, Camera Controls, Effects), Pipeline with Remotion post-production, Seed Bracketing. **27 CLI commands total.**

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

# Cinema Studio (cinematic image/video with camera+lens presets)
~/.aidevops/agents/scripts/higgsfield-helper.sh cinema-studio "Epic landscape" --tab image --camera "Dolly Zoom"

# Motion Control (animate character with motion reference video)
~/.aidevops/agents/scripts/higgsfield-helper.sh motion-control --video-file dance.mp4 --image-file character.jpg

# Edit/Inpaint (5 models: soul_inpaint, banana_placement, canvas, multi, nano_banana_pro_inpaint)
~/.aidevops/agents/scripts/higgsfield-helper.sh edit "Replace background with beach" --image-file photo.jpg -m soul_inpaint

# Upscale (AI upscale image or video)
~/.aidevops/agents/scripts/higgsfield-helper.sh upscale --image-file low-res.jpg

# Asset Library (browse, filter, download)
~/.aidevops/agents/scripts/higgsfield-helper.sh manage-assets --asset-action list --filter video

# Check credits and unlimited models
~/.aidevops/agents/scripts/higgsfield-helper.sh credits

# Download latest video from History
~/.aidevops/agents/scripts/higgsfield-helper.sh download --model video
```

## Architecture

```text
higgsfield-helper.sh (shell wrapper)
  └── higgsfield/playwright-automator.mjs (Playwright automation, ~4900 lines)
        ├── Persistent auth state (~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json)
        ├── Site discovery cache (~/.aidevops/.agent-workspace/work/higgsfield/routes-cache.json)
        ├── Credentials from ~/.config/aidevops/credentials.sh
        ├── Downloads to ~/Downloads/higgsfield/ (interactive) or .agent-workspace (headless)
        ├── Descriptive filenames: hf_{model}_{quality}_{prompt}_{ts}.ext
        ├── JSON sidecar metadata (.json alongside each download)
        ├── SHA-256 dedup index (.dedup-index.json per output dir)
        └── Project dirs via --project (organized by type: images/, videos/, etc.)
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

Higgsfield has 38+ apps for one-click content creation (visible on /apps page):

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

**Popular apps**: face-swap, 3d-render, comic-book, transitions, recast, skin-enhancer, angles, relight, shots, zooms, poster, sketch-to-real, renaissance, mugshot, character-swap, outfit-swap, link-to-video-ad, plushies, sticker-matchcut, surrounded-by-animals

### Cinema Studio

Professional cinematic image/video with camera and lens simulation presets.

```bash
# Cinematic image with camera preset
higgsfield-helper.sh cinema-studio "Epic mountain landscape at golden hour" --tab image --camera "Dolly Zoom"

# Cinematic video
higgsfield-helper.sh cinema-studio "Dramatic reveal of ancient temple" --duration 10 --lens "Anamorphic"

# With quality and aspect
higgsfield-helper.sh cinema-studio "Product hero shot" --tab image --quality 4K --aspect 16:9
```

Controls: Image/Video tab, camera presets (Dolly Zoom, Tracking, etc.), lens presets (Anamorphic, etc.), quality (1K/2K/4K), aspect ratio, batch count. Cost: 20 credits (has free generations).

### Motion Control

Animate a character image using a motion reference video.

```bash
# Upload dance video as motion reference + character image
higgsfield-helper.sh motion-control --video-file dance.mp4 --image-file character.jpg

# With prompt guidance
higgsfield-helper.sh motion-control --motion-ref walk.mp4 --image-file person.jpg -p "Walking through park"

# Unlimited mode (Kling)
higgsfield-helper.sh motion-control --video-file ref.mp4 --image-file face.jpg --unlimited
```

Accepts `--video-file` or `--motion-ref` for the reference video (3-30s), `--image-file` for the character. Cost: UNLIMITED with Kling.

### Edit/Inpaint

Upload an image and edit/inpaint specific regions with 5 available models.

```bash
# Soul Inpaint (default)
higgsfield-helper.sh edit "Replace background with tropical beach" --image-file photo.jpg

# Product placement (Banana Placement model)
higgsfield-helper.sh edit "Place product on marble table" --image-file product.jpg -m banana_placement

# Multi-reference (two images)
higgsfield-helper.sh edit "Combine styles" --image-file base.jpg --image-file2 reference.jpg -m multi

# Canvas model
higgsfield-helper.sh edit "Extend the scene" --image-file photo.jpg -m canvas
```

Models: `soul_inpaint` (default), `nano_banana_pro_inpaint`, `banana_placement`, `canvas`, `multi`. The `--image-file2` flag provides a second reference image for multi-reference and product placement models.

### Upscale

AI upscale an image or video to higher resolution.

```bash
# Upscale an image
higgsfield-helper.sh upscale --image-file low-res.jpg

# Upscale a video
higgsfield-helper.sh upscale --video-file clip.mp4

# Custom output
higgsfield-helper.sh upscale --image-file photo.jpg --output ~/Projects/hires/
```

### Asset Library

Browse, filter, and download from the Higgsfield asset library.

```bash
# List all assets
higgsfield-helper.sh manage-assets --asset-action list

# List filtered by type
higgsfield-helper.sh manage-assets --asset-action list --filter video
higgsfield-helper.sh manage-assets --asset-action list --filter lipsync

# Download latest asset
higgsfield-helper.sh manage-assets --asset-action download-latest --filter image

# Download specific asset by index
higgsfield-helper.sh manage-assets --asset-action download --asset-index 3

# Bulk download (up to N assets)
higgsfield-helper.sh manage-assets --asset-action download-all --limit 20
```

Filters: `image`, `video`, `lipsync`, `upscaled`, `liked`. Actions: `list`, `download`, `download-latest`, `download-all`.

### Asset Chaining ("Open in")

Chain an existing asset directly to another tool without downloading and re-uploading. Uses the "Open in" menu from the asset detail dialog.

```bash
# Animate an asset (send to video generation)
higgsfield-helper.sh chain --chain-action animate --asset-index 0

# Inpaint an asset with a prompt
higgsfield-helper.sh chain --chain-action inpaint -p "Replace background with sunset" --asset-index 0

# Upscale the latest asset
higgsfield-helper.sh chain --chain-action upscale --asset-index 0

# Relight, change angles, or apply AI styling
higgsfield-helper.sh chain --chain-action relight --asset-index 2
higgsfield-helper.sh chain --chain-action angles --asset-index 0
higgsfield-helper.sh chain --chain-action ai-stylist --asset-index 0
```

Available actions: `animate`, `inpaint`, `upscale`, `relight`, `angles`, `shots`, `ai-stylist`, `skin-enhancer`, `multishot`. The `--asset-index` selects which asset to chain (0 = latest).

### Mixed Media Presets

Apply visual transformation presets (32+ presets with UUID-based URLs).

```bash
# Apply sketch preset
higgsfield-helper.sh mixed-media --preset sketch --image-file photo.jpg

# Apply noir preset
higgsfield-helper.sh mixed-media --preset noir --image-file photo.jpg

# Other presets: layer, canvas, flash_comic, overexposed, paper, particles,
# hand_paint, toxic, vintage, comic, origami, marble, lava, ocean, magazine,
# modern, acid, tracking, ultraviolet, glitch, neon, watercolor, blueprint,
# thermal, xray, infrared, hologram, pixelate, mosaic
```

### Motion/VFX Presets

Apply motion or VFX effects from 150+ presets discovered dynamically.

```bash
# List available presets
higgsfield-helper.sh motion-preset

# Apply a preset by name
higgsfield-helper.sh motion-preset --preset dolly_zoom --image-file photo.jpg

# Apply by UUID directly
higgsfield-helper.sh motion-preset --preset "a1b2c3d4-..." --image-file photo.jpg
```

Presets are discovered by `discover` and cached in `routes-cache.json`. Run `discover` to refresh.

### Video Edit

Edit an existing video with a character image overlay.

```bash
# Edit video with character
higgsfield-helper.sh video-edit --video-file clip.mp4 --image-file character.jpg -p "Character walks through scene"
```

### Storyboard Generator

Create multi-panel storyboards from a script or prompt.

```bash
# Generate storyboard
higgsfield-helper.sh storyboard -p "A hero's journey through a cyberpunk city" --scenes 6

# With style preset
higgsfield-helper.sh storyboard -p "Product launch story" --scenes 4 --preset "Cinematic"

# With reference image
higgsfield-helper.sh storyboard -p "Day in the life" --image-file reference.jpg
```

### Vibe Motion

Animated content creation with 5 sub-types.

```bash
# Poster animation
higgsfield-helper.sh vibe-motion -p "Product launch announcement" --tab posters --preset Corporate

# Text animation
higgsfield-helper.sh vibe-motion -p "Breaking News: AI Revolution" --tab text-animation --duration 10

# Infographics
higgsfield-helper.sh vibe-motion -p "Q4 Revenue Growth 45%" --tab infographics --preset Minimal

# Presentation
higgsfield-helper.sh vibe-motion -p "Company overview slides" --tab presentation --duration 30

# From scratch (default)
higgsfield-helper.sh vibe-motion -p "Abstract motion graphics" --image-file logo.png
```

Sub-types: `infographics`, `text-animation`, `posters`, `presentation`, `from-scratch`. Styles: Minimal, Corporate, Fashion, Marketing. Duration: Auto/5/10/15/30s. Cost: 8-60 credits.

### AI Influencer Studio

Create AI-generated influencer characters.

```bash
# Create human influencer
higgsfield-helper.sh influencer --preset Human -p "Fashion influencer, warm smile, studio lighting"

# Create fantasy character
higgsfield-helper.sh influencer --preset Elf -p "Ethereal forest guardian"

# With reference image
higgsfield-helper.sh influencer --image-file reference.jpg -p "Similar style influencer"
```

Character types: Human, Ant, Bee, Octopus, Alien, Elf, and more. Cost: 30 free generations.

### Character Profiles

Create persistent character profiles for consistent generation across sessions.

```bash
# Create character from photo
higgsfield-helper.sh character --image-file face.jpg -p "Sarah"

# With multiple reference photos
higgsfield-helper.sh character --image-file face1.jpg --image-file2 face2.jpg -p "Alex"
```

### Feature Pages

Generic handler for feature pages that follow the standard upload + generate pattern.

```bash
# Fashion Factory
higgsfield-helper.sh feature --feature fashion-factory --image-file outfit.jpg -p "Summer collection"

# UGC Factory
higgsfield-helper.sh feature --feature ugc-factory --image-file product.jpg -p "Unboxing review script"

# Photodump Studio
higgsfield-helper.sh feature --feature photodump-studio --image-file photo1.jpg

# Camera Controls
higgsfield-helper.sh feature --feature camera-controls --image-file scene.jpg

# Effects
higgsfield-helper.sh feature --feature effects --image-file photo.jpg

# Shorthand (command name = feature name)
higgsfield-helper.sh fashion-factory --image-file outfit.jpg
higgsfield-helper.sh ugc-factory --image-file product.jpg
higgsfield-helper.sh effects --image-file photo.jpg
```

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
| Wan 2.5 Fast | varies | varies | varies |
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

The account has 19 unlimited models (no credit cost). The automator **auto-selects the best unlimited model** by default, ranked by SOTA quality for product/commercial photography.

**Auto-selection** (default behavior): When no `--model` is specified, the automator checks the credits cache for active unlimited models and picks the highest-quality one. This is controlled by `--prefer-unlimited` (on by default). Use `--no-prefer-unlimited` to disable.

**Image models** (ranked by SOTA quality for product shots):

| Priority | Model | Slug | Strength |
|----------|-------|------|----------|
| 1 | GPT Image | `gpt` | Best photorealism, text rendering |
| 2 | Seedream 4.5 | `seedream-4-5` | Excellent detail (ByteDance) |
| 3 | FLUX.2 Pro | `flux` | Strong commercial imagery |
| 4 | Flux Kontext | `kontext` | Context-aware editing |
| 5 | Reve | `reve` | Good photorealism |
| 6 | Nano Banana Pro | `nano-banana-pro` | Higgsfield premium |
| 7 | Soul | `soul` | Reliable all-rounder |
| 8 | Kling O1 Image | `kling_o1` | Decent quality |
| 9 | Seedream 4.0 | `seedream` | Older generation |
| 10 | Nano Banana | `nano_banana` | Standard tier |
| 11 | Z Image | `z_image` | Less established |
| 12 | Popcorn | `popcorn` | Stylized/creative |

**Video models** (ranked by quality):

| Priority | Model | Slug | Strength |
|----------|-------|------|----------|
| 1 | Kling 2.6 | `kling-2.6` | Best quality/speed |
| 2 | Kling O1 Video | `kling-o1` | Higher quality, slower |
| 3 | Kling 2.5 Turbo | `kling-2.5` | Fast, lower quality |

**Other unlimited**: Kling O1 Video Edit, Kling 2.6 Motion Control, Face Swap

**Credit cost**: Unlimited models return 0 from the credit guard, so they never trigger low-credit warnings or blocks.

**Unlimited model routing**: Models with "365" subscriptions use dedicated feature pages (e.g., `/nano-banana-pro`, `/seedream-4-5`) that have an "Unlimited" toggle switch. The automator automatically navigates to these pages and enables the switch. Standard `/image/` routes cost credits even for subscribed models.

**Self-tests**: Run `node playwright-automator.mjs test` to verify unlimited model selection logic (44 tests).

## Output Organization

### Default Output Paths

The default output directory depends on session context:

| Context | Default Output | Reason |
|---------|---------------|--------|
| Interactive (TTY / `--headed`) | `~/Downloads/higgsfield/` | Visible in Finder for immediate review |
| Headless / pipeline | `~/.aidevops/.agent-workspace/work/higgsfield/output/` | Keeps automation artifacts separate |

Override with `--output` to save anywhere.

### Project Directories

Use `--project` to organize outputs into structured directories:

```bash
# Without --project: files go to ~/Downloads/higgsfield/ (interactive)
higgsfield-helper.sh image "A sunset"

# With --project: files go to ~/Downloads/higgsfield/my-video/images/
higgsfield-helper.sh image "A sunset" --project my-video

# Explicit output overrides the default
higgsfield-helper.sh image "A sunset" --output ~/Projects/assets/
```

Directory structure with `--project`:

```text
{output}/{project}/
├── images/          # Image generations
├── videos/          # Video generations
├── lipsync/         # Lipsync outputs
├── edits/           # Edit/inpaint results
├── upscaled/        # Upscaled media
├── cinema/          # Cinema Studio outputs
├── storyboards/     # Storyboard panels
├── characters/      # Character/influencer outputs
├── apps/            # App/effect results
├── chained/         # Asset chain outputs
├── mixed-media/     # Mixed media preset results
├── motion-presets/  # Motion/VFX preset results
├── features/        # Feature page outputs
├── seed-brackets/   # Seed bracketing results
├── pipeline/        # Pipeline outputs
└── misc/            # Other downloads
```

### Descriptive Filenames

All downloads use descriptive filenames:

```text
hf_{model}_{quality}_{preset}_{prompt-slug}_{timestamp}_{index}.{ext}
```

Example: `hf_higgsfield-soul_2k_sunset-beach_a-serene-mountain-landscape_20260209193400_1.png`

Metadata is extracted from the Asset showcase dialog before downloading.

### JSON Sidecar Metadata

Every downloaded file gets a companion `.json` sidecar with full metadata:

```bash
ls ~/Downloads/my-video/images/
# hf_soul_2k_a-serene-mountain-landscape_20260210120000_1.png
# hf_soul_2k_a-serene-mountain-landscape_20260210120000_1.png.json
```

Sidecar contents:

```json
{
  "source": "higgsfield-ui-automator",
  "version": "1.0",
  "timestamp": "2026-02-10T12:00:00.000Z",
  "file": "hf_soul_2k_a-serene-mountain-landscape_20260210120000_1.png",
  "command": "image",
  "type": "image",
  "model": "Higgsfield Soul",
  "quality": "2k",
  "preset": "General",
  "promptSnippet": "A serene mountain landscape at golden hour, photorealistic",
  "fileSize": 2456789,
  "fileSizeHuman": "2.3MB"
}
```

Disable with `--no-sidecar`.

### Deduplication

SHA-256 hash-based deduplication prevents downloading the same file twice. A `.dedup-index.json` file in each output directory tracks file hashes. Duplicate downloads are automatically skipped.

Disable with `--no-dedup`.

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

Output goes to `{default-output}/pipeline-{timestamp}/` with all intermediate files and a `pipeline-state.json` manifest.

### Performance

| Scenes | Sequential | Parallel | Savings |
|--------|-----------|----------|---------|
| 1 | ~4 min | ~4 min | -- |
| 2 | ~8 min | ~4 min | 50% |
| 5 | ~20 min | ~4 min | 80% |
| 10 | ~40 min | ~5 min | 87% |

Video generation time is dominated by Higgsfield's server-side processing (~3-4 min per video). Parallel submission means all videos process concurrently.

## Trinity UGC Windows Template

Pre-built 3-step pipeline for creating Windows-style UGC (user-generated content) videos. Combines image generation, the Windows mixed-media preset, and video animation into a single command.

### Steps

1. **Image generation** - Generate a product/character image (or use `--image-file`)
2. **Windows preset** - Apply the Windows mixed-media visual effect (retro Windows aesthetic)
3. **Video animation** - Animate the result into a UGC-style video

### Usage

```bash
# Generate image + apply Windows preset + animate to video
higgsfield-helper.sh trinity-ugc-windows "Product on marble table, clean aesthetic"

# Use an existing image (skip step 1)
higgsfield-helper.sh trinity-ugc-windows --image-file product.jpg

# With video model and prompt overrides
higgsfield-helper.sh trinity-ugc-windows -p "Fashion model, studio lighting" \
  --video-model kling-2.6 --video-prompt "Smooth zoom in, product showcase"

# With aspect ratio and output directory
higgsfield-helper.sh trinity-ugc-windows -p "Sneakers on display" --aspect 9:16 -o ~/Projects/ugc/

# Dry run (configure but don't generate — no credits used)
higgsfield-helper.sh trinity-ugc-windows -p "Product shot" --dry-run
```

### Options

| Option | Description |
|--------|-------------|
| `--prompt, -p` | Image generation prompt (required unless `--image-file` provided) |
| `--image-file` | Skip image generation, use this file as source |
| `--model, -m` | Image model override (default: best unlimited or soul) |
| `--video-model` | Video model override (default: best unlimited or kling-2.6) |
| `--video-prompt` | Video animation prompt (default: derived from image prompt) |
| `--aspect, -a` | Aspect ratio (default: 9:16 for vertical UGC) |
| `--output, -o` | Output directory |
| `--project` | Project name for organized output dirs |
| `--dry-run` | Configure but don't generate |

### Aliases

All three aliases route to the same command:

- `trinity-ugc-windows` (full name)
- `trinity-windows` (short)
- `ugc-windows` (shortest)

### Output

Output goes to `{default-output}/trinity-ugc-windows/` (or `{project}/trinity-ugc-windows/` with `--project`). Includes:

- Source image (step 1)
- Windows-preset image/video (step 2)
- Final animated video (step 3)
- `trinity-state.json` manifest with timing and step results

### Cost

~30 credits total (image: ~2 + Windows preset: ~10 + video: ~20). Zero credits if all models are unlimited.

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

Results saved to `{default-output}/seed-bracket-{timestamp}/` with `bracket-results.json` manifest.

## CLI Options Reference

```text
--prompt, -p       Text prompt for generation
--model, -m        Model slug (soul, nano_banana, seedream, kling-2.6, gpt, kontext, flux)
--aspect, -a       Aspect ratio (16:9, 9:16, 1:1, 3:4, 4:3, 2:3, 3:2)
--quality, -q      Quality setting (1K, 1.5K, 2K, 4K)
--output, -o       Output directory (default: ~/Downloads/higgsfield/ interactive,
                   .agent-workspace headless)
--headed           Run browser in headed mode (visible, outputs to ~/Downloads/higgsfield/)
--headless         Run browser in headless mode (default, outputs to .agent-workspace)
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
--unlimited        Prefer unlimited models only (legacy)
--prefer-unlimited Auto-select best unlimited model by SOTA quality (default: on)
--no-prefer-unlimited  Use default models even if unlimited alternatives exist
--preset, -s       Style preset name (e.g., "Sunset beach", "CCTV")
--seed             Seed number for reproducible generation
--seed-range       Seed range for bracketing (e.g., "1000-1010")
--brief            Path to pipeline brief JSON file
--character-image  Character face image for pipeline
--video-model      Video model override for trinity/pipeline (e.g., kling-2.6)
--video-prompt     Video animation prompt override for trinity/pipeline
--dialogue         Dialogue text for lipsync in pipeline
--scenes           Number of scenes to generate
--video-file       Path to video file (motion reference for motion-control)
--motion-ref       Alias for --video-file (motion reference video)
--image-file2      Second image file (multi-reference edit, product placement)
--camera           Camera preset for cinema-studio (e.g., "Dolly Zoom")
--lens             Lens preset for cinema-studio (e.g., "Anamorphic")
--tab              Tab selection: "image" or "video" (cinema-studio)
--filter           Asset filter: image, video, lipsync, upscaled, liked
--asset-action     Asset action: list, download, download-latest, download-all
--asset-type       Asset type filter for manage-assets
--asset-index      Index of specific asset to download (0-based)
--limit            Max number of assets to download
--chain-action     Asset chain action: animate, inpaint, upscale, relight, angles, shots, ai-stylist, skin-enhancer, multishot
--feature          Feature page slug: fashion-factory, ugc-factory, photodump-studio, camera-controls, effects
--subtype          Vibe Motion sub-type: infographics, text-animation, posters, presentation, from-scratch
--project          Project name for organized output dirs ({output}/{project}/{type}/)
--no-sidecar       Disable JSON sidecar metadata files
--no-dedup         Disable SHA-256 duplicate detection
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
