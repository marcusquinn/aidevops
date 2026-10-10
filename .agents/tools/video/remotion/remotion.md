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

**Use when**: programmatic video generation, React-based animations, rendering pipelines, captions/subtitles, social media video automation, maps/geographic flyovers, SaaS/app integration.

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

Paths below are relative to this directory (`tools/video/remotion/`; source checkout: `.agents/tools/video/remotion/`):

**Core animation & timing:** `remotion-timing.md` | `remotion-timing-props.md` | `remotion-sequencing.md` | `remotion-transitions.md` | `remotion-interactivity.md` | `remotion-inline-effects.md`

**Compositions & metadata:** `remotion-compositions.md` | `remotion-connected-compositions.md` | `remotion-calculate-metadata.md` | `remotion-multi-scene-video.md` | `remotion-parameters.md`

**Media embedding:** `remotion-video-editing.md` | `remotion-embedding-videos.md` | `remotion-audio.md` | `remotion-voiceover.md` | `remotion-sfx.md` | `remotion-images.md` | `remotion-cropping.md` | `remotion-google-fonts.md` | `remotion-local-fonts.md` | `remotion-gifs.md` | `remotion-ffmpeg.md` | `remotion-silence-detection.md`

**Text & data visualization:** `remotion-text-highlights.md` | `remotion-lottie.md` | `remotion-3d.md` | `remotion-html-in-canvas.md` | `remotion-audio-visualization.md` | `remotion-light-leaks.md` | `remotion-motion-blur.md` | `remotion-measuring-dom-nodes.md` | `remotion-measuring-text.md`

**Maps:** `remotion-maps.md` (router) → `remotion-maps-static-map.md` | `remotion-maps-mapbox.md` | `remotion-maps-maplibre.md` | `remotion-maps-maptiler.md` | `remotion-maps-cesium.md`

**Captions & subtitles:** `remotion-captions.md` (router) → `remotion-transcribe-captions.md` | `remotion-display-captions.md` | `remotion-import-srt-captions.md`

**Multimedia (Mediabunny):** `remotion-multimedia.md` (router) → `remotion-get-audio-duration.md` | `remotion-get-video-dimensions.md` | `remotion-get-video-duration.md`

**SaaS/apps:** `remotion-saas.md` (router) → `remotion-saas-framework.md` | `remotion-saas-player.md` | `remotion-saas-rendering.md`

**Rendering & setup:** `remotion-render.md` → `remotion-transparent-videos.md` | `remotion-studio.md` | `remotion-create.md` → `remotion-tailwind.md` | `remotion-video-layout.md` | `remotion-docs.md` | `remotion-upgrade.md`

## CLI Commands

After rendering, run `media-qa-helper.sh probe out/video.mp4` to verify colour metadata alongside the stream details. For motion films, follow the frame critique in `tools/video/motion-design.md` (contact sheets, transition strips, loop and determinism checks).

```bash
npx remotion studio                                    # Dev studio
npx remotion render src/index.ts MyComp out/video.mp4  # Render video
npx remotion still src/index.ts MyStill out/thumb.png  # Render still
npx remotion render src/index.ts MyComp out/video.mp4 --props='{"title":"Custom"}'
npx remotion render src/index.ts MyComp out/video.mp4 --codec=h264 --crf=15 --pixel-format=yuv420p --color-space=bt709 # BT.709 delivery
ffprobe -v error -select_streams v:0 -show_entries stream=pix_fmt,color_range,color_space -of default=noprint_wrappers=1 out/video.mp4
```

For H.264 delivery, confirm the probe reports `yuv420p` and `bt709` (TV/limited range). Remotion 4.0.529 default output was observed as full-range `yuvj420p`/`bt470bg`; verify the rendered file rather than assuming defaults.

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

## Upstream router

## Preserve user changes

Users may make edits in the code outside of the conversation.

If you detect a surprising change made in the meanwhile, don't overwrite it, assume it was intentional or ask for confirmation.

## Creating a video

If the user asks to make, create, or build a new video or composition, load [Create a new Remotion video](remotion-create.md), whether or not a Remotion project already exists.

## New project setup

If no Remotion project currently exists, load [Create a new Remotion project](remotion-create.md)

## React Markup Best Practices

If you are writing Remotion React Markup, load [Remotion Markup Best Practices](remotion-markup.md)

## Maps

For static maps, animated routes and markers, geographic explainers, Mapbox, MapLibre, MapTiler, GeoJSON, or 3D geographic flyovers, load [Remotion Maps](remotion-maps.md).

## Multimedia

For achieving multimedia tasks in the browser, such as trimming, cropping videos, or getting metadata from them, load [Remotion Multimedia](remotion-multimedia.md)

## Improving Interactivity

By structuring the Remotion markup well, we can allow users to interactively change things in the Studio and write back to code. If relevant: [Interactivity Best Practices](remotion-interactivity.md)

## Open the preview

If the user asks to "make" a video, "create" a video, etc.
Don't render the video by default unless they are very explicit. They want to instead see an interactive preview.
As soon as the project can run, start Studio and open the preview in the browser before building or editing the composition. Keep it open while you work so the user can watch progress and steer.

### If you are using Cursor

Run Studio without `--no-open` so it opens the browser automatically:

```bash
npx remotion studio
```

### If you are using another agent client with an in-app browser

You can use the command above to let Studio open the browser, or run:

```bash
npx remotion studio --no-open
```

This will start a long-running process and print the server URL for the preview.<br>
If the server is already started, it will print the URL.
If you use `--no-open`, open the exact printed URL in the in-app browser and verify that Studio loads. Once a composition exists, verify that its video preview loads. If you cannot open it there, run Studio without `--no-open`.
You can visit a specific composition by navigating to `/[composition-id]`, for example `http://localhost:3000/MapAnimation`.

:::note
The Studio supports WebMCP tools.
:::

### If you do not have an in-app browser

This will open the Studio in the browser or refocus it if it is already open.

```bash
npx remotion studio
```

### More options

To launch a project in Remotion Studio, open its exact local URL, or configure Studio CLI flags, load [Remotion Studio](remotion-studio.md).

## Render the video

Only render if the user is very explicit in asking for it.<br>
E.g. "Render the video", "Export", "Give me the MP4".

The preview also has a more intuitive rendering interface, so consider using it instead of the command line for rendering.

```text
npx remotion render
```

For more options, see [Rendering](remotion-render.md).

For advanced rendering beyond simple `npx remotion render`, see: [Rendering Best Practices](remotion-render.md)

## Captions

When working with Captions, load [Remotion Captions](remotion-captions.md).

## Creating a SaaS, automation or application

Use the [Remotion SaaS skill](remotion-saas.md) for knowledge about Remotion-powered SaaS apps, such as `<Player>`, rendering on Lambda, Vercel, Cloudflare, via Express.js, client-side rendering, or for finding the right SaaS template.

## Looking up Remotion APIs and documentation

To find and read current Remotion documentation, load [Remotion Docs](remotion-docs.md).

## Upgrading

To upgrade Remotion, related packages, compatible Mediabunny packages, and installed Remotion Agent Skills, load [Remotion Upgrade](remotion-upgrade.md).
