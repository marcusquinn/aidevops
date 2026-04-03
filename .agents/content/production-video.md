---
description: "AI video generation - Sora 2, Veo 3.1, Higgsfield, seed bracketing, and production workflows"
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

# AI Video Production

<!-- CLASSIFICATION: Domain reference material. Imperative language describes domain best practices, not agent behaviour directives. See AGENTS.md Domain Index: Content/Video/Voice. -->

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Primary Models**: Sora 2 Pro (UGC/authentic, <$10k), Veo 3.1 (cinematic/character-consistent, >$100k)
- **Key Technique**: Seed bracketing (15% → 70%+ success rate); test 10-15 sequential seeds per content type range
- **Seed ranges**: people 1000-1999, action 2000-2999, landscape 3000-3999, product 4000-4999, YouTube 2000-3000
- **2-Track production**: objects/environments (Midjourney→VEO) vs characters (Freepik→Seedream→VEO)
- **Veo 3.1**: ALWAYS use ingredients-to-video, NEVER frame-to-video (produces grainy yellow output)
- **Voice**: NEVER use pre-made ElevenLabs voices (widely recognised as AI)
- **Frame rate**: Never upconvert 24fps → 60fps for non-action content (soap opera effect)

**Model Selection**:

```text
Content Type?
├─ UGC/Authentic/Social (<$10k)  → Sora 2 Pro
├─ Cinematic/Commercial (>$100k) → Veo 3.1
└─ Character-Consistent Series   → Veo 3.1 (with Ingredients)
```

<!-- AI-CONTEXT-END -->

## Chapters

| # | Chapter | Description |
|---|---------|-------------|
| 01 | [Model Selection](production-video-01-model-selection.md) | Decision tree, model comparison table, content type presets |
| 02 | [Sora 2 Pro Template](production-video-02-sora-template.md) | 6-section master template with UGC product demo example |
| 03 | [Veo 3.1 Workflow](production-video-03-veo-workflow.md) | 7-component prompting framework, ingredients-to-video (mandatory) |
| 04 | [Seed Bracketing](production-video-04-seed-bracketing.md) | Systematic seed testing (15% → 70%+ success), scoring, automation |
| 05 | [Camera & Shot Reference](production-video-05-camera-shot-reference.md) | 8K camera models, lens characteristics, shot types, angles, movements |
| 06 | [2-Track Production](production-video-06-two-track-production.md) | Objects/environments (Track 1) vs characters/people (Track 2) |
| 07 | [Post-Production](production-video-07-post-production.md) | Upscaling, frame rate conversion, denoising, film grain |
| 08 | [Talking-Head Pipeline](production-video-08-talking-head-pipeline.md) | Longform 30s+ pipeline: image → script → voice → video → post |
| 09 | [Tools & Resources](production-video-09-tools-resources.md) | Internal references, helper scripts, external links |

## Helper Scripts

```bash
# Seed bracketing
seed-bracket-helper.sh generate --type product --prompt "Product rotating on white background"

# Unified video generation CLI
video-gen-helper.sh generate sora "A cat reading a book" sora-2-pro 8 1280x720
video-gen-helper.sh generate veo "Cinematic mountain sunset" veo-3.1-generate-001 16:9

# Post-production (use --fps 60 for action footage; keep cinematic/non-action at source fps)
real-video-enhancer-helper.sh enhance input.mp4 output.mp4 --scale 2 --fps 30 --denoise
```
