---
name: remotion
description: "Remotion - Programmatic video creation with React. Animations, compositions, media handling, captions, and rendering."
mode: subagent
imported_from: external
upstream_url: https://github.com/remotion-dev/skills
context7_id: /remotion-dev/remotion
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Remotion

Programmatic video creation using React with frame-by-frame control.

**Use when**: programmatic video generation, React-based animations, rendering pipelines, captions/subtitles, social media video automation.

## Quick Reference

| Concept | Import | Purpose |
|---------|--------|---------|
| `useCurrentFrame()` | `remotion` | Current frame number |
| `useVideoConfig()` | `remotion` | fps, width, height, duration |
| `interpolate()` | `remotion` | Linear value mapping |
| `spring()` | `remotion` | Physics-based animations |
| `<Composition>` | `remotion` | Define renderable video |
| `<Sequence>` | `remotion` | Time-offset content |
| `<Video>` / `<Audio>` | `@remotion/media` | Embed video/audio files |
| `<Img>` | `remotion` | Embed images |

## Critical Rules

**FORBIDDEN** (will not render): CSS transitions/animations, Tailwind `animate-*`, `setTimeout`/`setInterval`, React state for animation values.

**REQUIRED**: All animations via `useCurrentFrame()`. Time = `seconds * fps`. Motion via `interpolate()` or `spring()`.

## Chapter Files

Paths below are relative to the active agent root (`~/.aidevops/agents/` by default; source checkout: `.agents/`):

**Core animation & timing:**
`tools/video/remotion-animations.md` | `tools/video/remotion-timing.md` | `tools/video/remotion-sequencing.md` | `tools/video/remotion-trimming.md` | `tools/video/remotion-transitions.md`

**Compositions & metadata:**
`tools/video/remotion-compositions.md` | `tools/video/remotion-calculate-metadata.md`

**Media embedding:**
`tools/video/remotion-videos.md` | `tools/video/remotion-audio.md` | `tools/video/remotion-images.md` | `tools/video/remotion-assets.md` | `tools/video/remotion-fonts.md` | `tools/video/remotion-gifs.md`

**Text & data visualization:**
`tools/video/remotion-text-animations.md` | `tools/video/remotion-charts.md` | `tools/video/remotion-lottie.md` | `tools/video/remotion-3d.md`

**Captions & subtitles:**
`tools/video/remotion-transcribe-captions.md` | `tools/video/remotion-display-captions.md` | `tools/video/remotion-import-srt-captions.md`

**Utilities:**
`tools/video/remotion-can-decode.md` | `tools/video/remotion-extract-frames.md` | `tools/video/remotion-get-audio-duration.md` | `tools/video/remotion-get-video-duration.md` | `tools/video/remotion-get-video-dimensions.md` | `tools/video/remotion-measuring-dom-nodes.md` | `tools/video/remotion-measuring-text.md`

**Setup:**
`tools/video/remotion-tailwind.md`

## CLI Commands

```bash
npx remotion studio                                    # Dev studio
npx remotion render src/index.ts MyComp out/video.mp4  # Render video
npx remotion still src/index.ts MyStill out/thumb.png  # Render still
npx remotion render src/index.ts MyComp out/video.mp4 --props='{"title":"Custom"}'
```

## Context7

For up-to-date API docs: `/context7 remotion [query]`

## Examples & Inspiration

| Repository | Key Patterns |
|-----------|--------------|
| [trycua/launchpad](https://github.com/trycua/launchpad) | Scene-based architecture, monorepo, word-by-word text, spring physics, blur transitions |
| [remotion-dev/trailer](https://github.com/remotion-dev/trailer) | Advanced compositions, transitions, brand animation |
| [remotion-dev/github-unwrapped](https://github.com/remotion-dev/github-unwrapped) | Data-driven video, dynamic props, SSR at scale |
| [remotion-dev/template-helloworld](https://github.com/remotion-dev/template-helloworld) | Minimal project structure, basic patterns |

**Architectural patterns**: Scene components with exported duration constants, monorepo shared animations/brand assets, centralized constants (`VIDEO_WIDTH`, `VIDEO_HEIGHT`, `VIDEO_FPS`), `<Series>` for sequential scene chaining.

## Related

- [Remotion Docs](https://www.remotion.dev/docs)
- [Context7 Remotion](/remotion-dev/remotion)
- `tools/browser/playwright.md` — Browser automation for video assets
