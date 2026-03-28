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
| `useCurrentFrame()` | `remotion` | Get current frame number |
| `useVideoConfig()` | `remotion` | Get fps, width, height, duration |
| `interpolate()` | `remotion` | Linear value mapping |
| `spring()` | `remotion` | Physics-based animations |
| `<Composition>` | `remotion` | Define renderable video |
| `<Sequence>` | `remotion` | Time-offset content |
| `<Video>` | `@remotion/media` | Embed video files |
| `<Audio>` | `@remotion/media` | Embed audio files |
| `<Img>` | `remotion` | Embed images |

## Critical Rules

**FORBIDDEN** (will not render):

- CSS transitions/animations, Tailwind `animate-*` classes
- `setTimeout`/`setInterval` for timing
- React state for animation values

**REQUIRED**:

- All animations driven by `useCurrentFrame()`
- Time: `seconds * fps` (from `useVideoConfig()`)
- Motion via `interpolate()` or `spring()`

## Chapter Files

Detailed patterns and code examples in `tools/video/remotion/`:

| File | Topic |
|------|-------|
| `animations.md` | Fundamental animation patterns |
| `timing.md` | Interpolation, easing, springs |
| `compositions.md` | Defining videos, stills, folders, dynamic metadata |
| `sequencing.md` | Delay, trim, limit duration |
| `trimming.md` | Cut beginning/end of animations |
| `videos.md` | Embedding videos |
| `audio.md` | Sound, volume, trimming |
| `images.md` | Image embedding |
| `assets.md` | Importing images, videos, audio, fonts |
| `fonts.md` | Google Fonts, local fonts |
| `gifs.md` | GIFs, APNG, AVIF, WebP |
| `text-animations.md` | Typography and text animation patterns |
| `charts.md` | Bar charts, pie charts, data-driven animations |
| `lottie.md` | Lottie animation embedding |
| `3d.md` | Three.js integration |
| `transitions.md` | Scene transitions |
| `tailwind.md` | TailwindCSS setup |
| `captions.md` | Transcription, subtitles (legacy) |
| `transcribe-captions.md` | Audio-to-caption transcription |
| `display-captions.md` | TikTok-style captions, word highlighting |
| `import-srt-captions.md` | Import .srt subtitle files |
| `calculate-metadata.md` | Dynamic duration, dimensions, props |
| `can-decode.md` | Browser video decode checking |
| `extract-frames.md` | Extract frames at specific timestamps |
| `get-audio-duration.md` | Audio duration in seconds |
| `get-video-duration.md` | Video duration in seconds |
| `get-video-dimensions.md` | Video width/height |
| `measuring-dom-nodes.md` | DOM element dimension measurement |
| `measuring-text.md` | Text dimensions, fitting, overflow |

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
| [trycua/launchpad](https://github.com/trycua/launchpad) | Scene-based architecture, shared packages, scaffolding CLI, word-by-word text, spring physics, blur transitions |
| [remotion-dev/trailer](https://github.com/remotion-dev/trailer) | Advanced compositions, transitions, brand animation |
| [remotion-dev/github-unwrapped](https://github.com/remotion-dev/github-unwrapped) | Data-driven video, dynamic props, SSR at scale |
| [remotion-dev/template-helloworld](https://github.com/remotion-dev/template-helloworld) | Minimal project structure, basic patterns |

**Architectural patterns**: scene components with exported duration constants, monorepo shared animations/brand assets, centralized constants (`VIDEO_WIDTH`, `VIDEO_HEIGHT`, `VIDEO_FPS`), `<Series>` for sequential scene chaining.

## Related

- [Remotion Docs](https://www.remotion.dev/docs)
- [Context7 Remotion](/remotion-dev/remotion)
- `tools/browser/playwright.md` - Browser automation for video assets
