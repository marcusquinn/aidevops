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

Browser-based automation for Higgsfield AI via Playwright. Uses **subscription credits** (UI-only, not API). Covers: image (10 models), video (4 workflows), lipsync (11 models), cinema studio, motion control, edit/inpaint (5 models), upscale, apps (38+), asset library, mixed media (32 presets), motion/VFX (150+ presets), vibe motion, storyboard, AI influencer, character profiles, pipeline + Remotion, seed bracketing. **27 CLI commands.**

Use instead of `higgsfield.md` when: subscription credits apply, UI-exclusive features needed, or API has no credits.

## Setup

**Prerequisites**: Node.js/Bun, Playwright (`npm install playwright && npx playwright install chromium`).

Credentials in `~/.config/aidevops/credentials.sh`: `HIGGSFIELD_USER`, `HIGGSFIELD_PASS`.

```bash
higgsfield-helper.sh setup
higgsfield-helper.sh login   # headed — handles 2FA/captcha; saves auth-state.json
```

## Architecture

```text
higgsfield-helper.sh → playwright-automator.mjs (~4900 lines)
  Auth/cache: ~/.aidevops/.agent-workspace/work/higgsfield/
  Filenames: hf_{model}_{quality}_{preset}_{prompt}_{ts}.ext + .json sidecar + SHA-256 dedup
```

## Commands

```bash
higgsfield-helper.sh image "prompt" [--model soul] [--aspect 16:9] [--quality 2k] [--batch 4] [--enhance] [--preset "Sunset beach"] [--seed N]
higgsfield-helper.sh video "Camera pans" --image-file photo.jpg [--model kling-2.6] [--duration 5] [--timeout 600000]
higgsfield-helper.sh lipsync "Hello world!" --image-file face.jpg [--model "Wan 2.5 Speak"]
higgsfield-helper.sh app face-swap --image-file photo.jpg
# Apps: face-swap, 3d-render, comic-book, transitions, recast, skin-enhancer, angles, relight, shots, zooms, poster, sketch-to-real, renaissance, mugshot, character-swap, outfit-swap, link-to-video-ad, plushies, sticker-matchcut, surrounded-by-animals
higgsfield-helper.sh cinema-studio "Epic landscape" --tab image --camera "Dolly Zoom" [--lens "Anamorphic"] [--quality 4K]
higgsfield-helper.sh motion-control --video-file dance.mp4 --image-file character.jpg [-p "prompt"]
higgsfield-helper.sh edit "Replace background with beach" --image-file photo.jpg [-m soul_inpaint]
# Edit models: soul_inpaint (default), nano_banana_pro_inpaint, banana_placement, canvas, multi
higgsfield-helper.sh edit "Combine styles" --image-file base.jpg --image-file2 ref.jpg -m multi
higgsfield-helper.sh upscale --image-file low-res.jpg
higgsfield-helper.sh manage-assets --asset-action list|download-latest|download-all [--filter image|video|lipsync|upscaled|liked] [--limit 20]
higgsfield-helper.sh chain --chain-action animate|inpaint|upscale|relight|angles|shots|ai-stylist|skin-enhancer|multishot --asset-index 0
higgsfield-helper.sh mixed-media --preset sketch|noir|layer|canvas|flash_comic|overexposed|paper|particles|hand_paint|toxic|vintage|comic|origami|marble|lava|ocean|magazine|modern|acid|tracking|ultraviolet|glitch|neon|watercolor|blueprint|thermal|xray|infrared|hologram|pixelate|mosaic --image-file photo.jpg
higgsfield-helper.sh motion-preset [--preset dolly_zoom --image-file photo.jpg]   # omit args to list
higgsfield-helper.sh video-edit --video-file clip.mp4 --image-file character.jpg -p "prompt"
higgsfield-helper.sh storyboard -p "A hero's journey" --scenes 6 [--preset "Cinematic"]
higgsfield-helper.sh vibe-motion -p "Product launch" --tab posters --preset Corporate
# Vibe sub-types: infographics, text-animation, posters, presentation, from-scratch. Styles: Minimal, Corporate, Fashion, Marketing. 8-60cr.
higgsfield-helper.sh influencer --preset Human -p "Fashion influencer, warm smile"  # 30 free gens
higgsfield-helper.sh character --image-file face.jpg -p "Sarah"
higgsfield-helper.sh feature --feature fashion-factory|ugc-factory|photodump-studio|camera-controls|effects --image-file photo.jpg
higgsfield-helper.sh credits
higgsfield-helper.sh download [--model video]
higgsfield-helper.sh seed-bracket "prompt" --seed-range 1000-1010 [--model nano_banana_pro]
# Seed ranges: people 1000-1999 | action 2000-2999 | landscape 3000-3999 | product 4000-4999
higgsfield-helper.sh pipeline --brief brief.json   # parallel submit: 5 scenes ~4min vs ~20min sequential
```

## Models

### Image (10 models)

| Model | Slug | Cost | Unlimited |
|-------|------|------|-----------|
| GPT Image | `gpt` | 2cr | Yes |
| Seedream 4.5 | `seedream-4-5` | 1cr | Yes |
| FLUX.2 Pro | `flux` | varies | Yes |
| Flux Kontext Max | `kontext` | 1.5cr | Yes |
| Nano Banana Pro | `nano-banana-pro` | 2cr | Yes |
| Higgsfield Soul | `soul` | 2cr | Yes |
| Kling O1 Image | `kling-o1` | varies | Yes |
| Seedream 4.0 | `seedream` | 1cr | Yes |
| Nano Banana | `nano_banana` | 1cr | Yes |
| WAN 2.2 | `wan2` | 1cr | No |

Ranked by quality for product shots (GPT → Seedream 4.5 → FLUX → Kontext → ...). `--prefer-unlimited` (default) auto-selects best unlimited model. Unlimited models use dedicated routes (e.g., `/nano-banana-pro`) — standard `/image/` routes cost credits even for subscribed models.

Soul presets: All, New, TikTok Core, Instagram Aesthetics, Camera Presets, Beauty, Mood, Surreal, Graphic Art.

### Video (5 models)

| Model | Resolution | Duration | Cost | Unlimited |
|-------|-----------|----------|------|-----------|
| Kling 3.0 (Exclusive) | 1080p | 3-15s | varies | No |
| Kling 2.6 | 1080p | 5-10s | 10cr | Yes |
| Kling 2.5 Turbo | 1080p | 5-10s | varies | Yes |
| Seedance 1.5 Pro | 720p | 4-12s | varies | No |
| Grok/Minimax/Sora 2/Veo/Wan | varies | varies | varies | No |

Unlimited ranking: Kling 2.6 → Kling O1 Video → Kling 2.5 Turbo. Also unlimited: Kling O1 Video Edit, Motion Control, Face Swap.

### Lipsync (11 models)

Wan 2.5 Fast, Kling 2.6 Lipsync, Google Veo 3, Veo 3 Fast, Wan 2.5 Speak (9cr), Wan 2.5 Speak Fast, Kling Avatars 2.0 (up to 5min), Higgsfield Speak 2.0, Infinite Talk, Kling Lipsync, Sync Lipsync 2 Pro (4K).

### Special Features (UI-only)

| Feature | Path | Cost |
|---------|------|------|
| Cinema Studio | `/cinema-studio` | 20cr (free gens) |
| Vibe Motion | `/vibe-motion` | 8-60cr |
| AI Influencer | `/ai-influencer-studio` | 30 free |
| Motion Control | `/create/motion-control` | UNLIMITED |
| Lipsync Studio | `/lipsync-studio` | 9+cr |

## Pipeline Brief JSON

```json
{
  "title": "Product Demo Short",
  "character": { "description": "Young woman, brown hair", "image": "/path/to/face.png" },
  "scenes": [{ "prompt": "Close-up holding product", "duration": 5, "dialogue": "Check this out!" }],
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

`imagePrompts[]` = start-frame image prompts. `captions[]` = Remotion overlay (styles: bold-white, minimal, impact, typewriter, highlight).

Remotion: `cd .agents/scripts/higgsfield/remotion && npm install` — animated captions, transitions (fade/slide/wipe), title cards, 1080×1920.

## Output

Interactive/`--headed` → `~/Downloads/higgsfield/` | Headless → `~/.aidevops/.agent-workspace/work/higgsfield/output/`

Override: `--output`. Subdirs per type: `--project`. Disable sidecar: `--no-sidecar`. Disable dedup: `--no-dedup`.

## Key CLI Options

```text
--model/-m       Model slug
--aspect/-a      16:9 | 9:16 | 1:1 | 3:4 | 4:3 | 2:3 | 3:2
--quality/-q     1K | 1.5K | 2K | 4K
--output/-o      Output directory
--headed/--headless  Browser mode (headless default)
--duration/-d    Video seconds (5, 10, 15)
--image-file     Input image path
--image-file2    Second image (multi-reference edit)
--video-file/--motion-ref  Motion reference video
--batch/-b       Images 1-4
--preset/-s      Style preset name
--seed           Seed number
--seed-range     1000-1010 or "4000,4003,4008"
--brief          Pipeline brief JSON path
--tab            image | video
--filter         image | video | lipsync | upscaled | liked
--asset-action   list | download | download-latest | download-all
--asset-index    0-based asset index
--chain-action   animate | inpaint | upscale | relight | angles | shots | ai-stylist | skin-enhancer | multishot
--feature        fashion-factory | ugc-factory | photodump-studio | camera-controls | effects
--subtype        Vibe Motion: infographics | text-animation | posters | presentation | from-scratch
--project        Organized output subdirs
--prefer-unlimited  Auto-select best unlimited model (default on)
```

## Prompt Tips

**Images**: Camera + lighting + lens. `"Golden retriever, golden hour, shallow DOF, Canon EOS R5, 85mm, bokeh"`

**Videos**: Camera movement first. `"Smooth cinematic pan left to right, golden hour, 24fps film grain"`

**Modifiers**: photorealistic → `"8k, highly detailed"` | cinematic → `"anamorphic, film grain, color graded"` | portrait → `"studio lighting, bokeh, 85mm"`

## Troubleshooting

```bash
rm ~/.aidevops/.agent-workspace/work/higgsfield/auth-state.json && higgsfield-helper.sh login  # auth reset
higgsfield-helper.sh image "test" --headed   # debug in browser
higgsfield-helper.sh download --model video  # video fallback (fnf.higgsfield.ai API)
npx playwright install chromium              # browser missing
```

Debug screenshots → `~/.aidevops/.agent-workspace/work/higgsfield/` (login-debug, image-page, generation-result, error).

Self-tests: `node playwright-automator.mjs test` (44 tests).

## Related

- `higgsfield.md` — API-based generation (requires API credits)
- `tools/browser/browser-automation.md` — Browser tool selection
- `tools/video/video-prompt-design.md` — Prompt engineering
