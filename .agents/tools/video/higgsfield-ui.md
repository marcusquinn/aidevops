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

Browser-based automation for Higgsfield AI using Playwright. This subagent drives the Higgsfield web UI to generate images, videos, and apply effects using **subscription credits** (which are only available through the UI, not the API).

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

# Generate image
~/.aidevops/agents/scripts/higgsfield-helper.sh image "A cyberpunk city at night"

# Generate video
~/.aidevops/agents/scripts/higgsfield-helper.sh video "Camera pans across landscape"

# Use an app/effect
~/.aidevops/agents/scripts/higgsfield-helper.sh app face-swap --image-file photo.jpg

# Check credits
~/.aidevops/agents/scripts/higgsfield-helper.sh credits

# List recent generations
~/.aidevops/agents/scripts/higgsfield-helper.sh assets
```

## Architecture

```text
higgsfield-helper.sh (shell wrapper)
  └── higgsfield/playwright-automator.mjs (Playwright automation)
        ├── Persistent auth state (~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json)
        ├── Credentials from ~/.config/aidevops/credentials.sh
        └── Downloads to ~/Downloads/
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
# Basic image
higgsfield-helper.sh image "A serene mountain landscape at golden hour"

# With model selection
higgsfield-helper.sh image "Portrait photo" --model nano_banana
higgsfield-helper.sh image "Anime character" --model seedream

# Headed mode (see the browser)
higgsfield-helper.sh image "Cyberpunk city" --headed

# Custom output
higgsfield-helper.sh image "Product photo" --output ~/Projects/assets/
```

### Video Generation

Video requires a start frame image. Generate an image first, then animate it:

```bash
# Step 1: Generate a start frame image
higgsfield-helper.sh image "A serene mountain landscape at golden hour"

# Step 2: Animate it (image-to-video)
higgsfield-helper.sh video "Camera slowly zooms in" --image-file ~/Downloads/hf_*.png

# With timeout for long generations (default 5 min)
higgsfield-helper.sh video "Epic landscape pan" --image-file photo.jpg --timeout 600000
```

### Apps and Effects

Higgsfield has 100+ apps for one-click content creation:

```bash
# Face swap
higgsfield-helper.sh app face-swap --image-file face.jpg

# 3D render
higgsfield-helper.sh app 3d-render --image-file product.jpg

# Comic book style
higgsfield-helper.sh app comic-book --image-file photo.jpg

# Transitions between shots
higgsfield-helper.sh app transitions --image-file shot1.jpg

# Sketch to real
higgsfield-helper.sh app sketch-to-real --image-file sketch.jpg
```

**Popular apps**: face-swap, 3d-render, comic-book, transitions, recast, skin-enhancer, angles, relight, shots, zooms, poster, sketch-to-real, renaissance, mugshot, character-swap, outfit-swap, click-to-ad, plushies, sticker-matchcut

### Account Management

```bash
# Check credits and plan
higgsfield-helper.sh credits

# List recent generations
higgsfield-helper.sh assets

# Check auth status
higgsfield-helper.sh status

# Take screenshot of any page
higgsfield-helper.sh screenshot https://higgsfield.ai/image/soul

# Download latest generation
higgsfield-helper.sh download
```

## Available Models (UI)

### Image Models

| Model | Slug | Best For |
|-------|------|----------|
| Soul | `soul` | High-aesthetic photos, portraits |
| Nano Banana Pro | `nano_banana` | 4K images, best quality |
| Seedream 4.5 | `seedream` | Next-gen 4K images |
| Flux Kontext | `kontext` | Context-aware generation |
| GPT Image | `gpt` | GPT-powered generation |
| Wan 2.2 | `wan2` | Versatile generation |

### Video Models (via UI)

| Model | Best For |
|-------|----------|
| DOP Standard/Turbo | Image animation |
| Kling 2.6 | Cinematic with audio |
| Kling 3.0 | Latest Kling model |
| Kling O1 | Reasoning-enhanced video |
| Seedance 2.0 | Professional multi-shot |
| Sora 2 | OpenAI video model |
| Wan 2.6 | Advanced video |
| Veo 3.1 | Google video model |
| MiniMax Hailuo 02 | Dynamic VFX |

### Special Features (UI-only)

| Feature | URL Path | Description |
|---------|----------|-------------|
| Cinema Studio | `/cinema-studio` | Multi-shot cinematic videos |
| Vibe Motion | `/vibe-motion` | Motion-designed videos from prompts |
| AI Influencer | `/ai-influencer-studio` | Create AI influencer characters |
| Lipsync Studio | `/lipsync-studio` | Talking avatar clips |
| Motion Control | `/create/motion-control` | Precise character control |
| Mixed Media | `/mixed-media-intro` | Artistic style presets |
| UGC Factory | `/ugc-factory` | User-generated content |
| Photodump Studio | `/photodump-studio` | Photo collections |

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

### Browser Not Found

```bash
npx playwright install chromium
```

## Debug Screenshots

All operations save debug screenshots to `~/.aidevops/.agent-workspace/work/higgsfield/`:

- `login-debug.png` - Login page state
- `image-page.png` - Image generation page
- `generation-result.png` - After generation
- `video-page.png` - Video generation page
- `assets-page.png` - Assets listing
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
