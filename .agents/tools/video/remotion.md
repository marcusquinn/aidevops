---
name: remotion
description: "Remotion - Programmatic video creation with React. Animations, compositions, media handling, captions, and rendering."
mode: subagent
imported_from: external
upstream_url: https://github.com/remotion-dev/skills
context7_id: /remotion-dev/remotion
---

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

Detailed patterns and code in `tools/video/remotion/`:

**Core animation & timing:**
`animations.md` | `timing.md` | `sequencing.md` | `trimming.md` | `transitions.md`

**Compositions & metadata:**
`compositions.md` | `calculate-metadata.md`

**Media embedding:**
`videos.md` | `audio.md` | `images.md` | `assets.md` | `fonts.md` | `gifs.md`

**Text & data visualization:**
`text-animations.md` | `charts.md` | `lottie.md` | `3d.md`

**Captions & subtitles:**
`transcribe-captions.md` | `display-captions.md` | `import-srt-captions.md`

**Utilities:**
`can-decode.md` | `extract-frames.md` | `get-audio-duration.md` | `get-video-duration.md` | `get-video-dimensions.md` | `measuring-dom-nodes.md` | `measuring-text.md`

**Setup:**
`tailwind.md`

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
