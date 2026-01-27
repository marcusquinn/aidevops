---
description: "Remotion - Programmatic video creation with React. Animations, compositions, media handling, captions, and rendering."
mode: subagent
imported_from: external
upstream_url: https://github.com/remotion-dev/skills
context7_id: /remotion-dev/remotion
---
# Remotion

Remotion is a framework for creating videos programmatically using React. It leverages web technologies for video creation with precise frame-by-frame control.

## When to Use

Read this skill when working with:
- Programmatic video generation
- React-based animations for video
- Automated video rendering pipelines
- Caption/subtitle generation
- Social media video automation

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

**FORBIDDEN patterns** (will not render correctly):
- CSS transitions or animations
- Tailwind animation classes (`animate-*`)
- `setTimeout`/`setInterval` for timing
- React state for animation values

**REQUIRED patterns**:
- All animations driven by `useCurrentFrame()`
- Time calculations: `seconds * fps` (from `useVideoConfig()`)
- Use `interpolate()` or `spring()` for all motion

## Basic Animation Pattern

```tsx
import { useCurrentFrame, useVideoConfig, interpolate } from "remotion";

export const FadeIn = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  // Fade in over 2 seconds
  const opacity = interpolate(frame, [0, 2 * fps], [0, 1], {
    extrapolateRight: 'clamp',
  });

  return <div style={{ opacity }}>Hello World!</div>;
};
```

## Spring Animation (Natural Motion)

```tsx
import { spring, useCurrentFrame, useVideoConfig, interpolate } from "remotion";

export const BounceIn = () => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();

  const scale = spring({
    frame,
    fps,
    config: { damping: 200 }, // Smooth, no bounce
  });

  return <div style={{ transform: `scale(${scale})` }}>Bouncy!</div>;
};
```

**Common spring configs:**
- `{ damping: 200 }` - Smooth, no bounce (reveals)
- `{ damping: 20, stiffness: 200 }` - Snappy (UI elements)
- `{ damping: 8 }` - Bouncy (playful)
- `{ damping: 15, stiffness: 80, mass: 2 }` - Heavy, slow

## Composition Setup

```tsx
// src/Root.tsx
import { Composition } from "remotion";
import { MyVideo } from "./MyVideo";

export const RemotionRoot = () => {
  return (
    <Composition
      id="MyVideo"
      component={MyVideo}
      durationInFrames={150}  // 5 seconds at 30fps
      fps={30}
      width={1920}
      height={1080}
      defaultProps={{
        title: "Hello World",
      }}
    />
  );
};
```

## Sequencing Content

```tsx
import { Sequence, AbsoluteFill } from "remotion";

export const MyVideo = () => {
  const { fps } = useVideoConfig();

  return (
    <AbsoluteFill>
      {/* Appears immediately */}
      <Sequence from={0}>
        <Title text="Welcome" />
      </Sequence>

      {/* Appears after 2 seconds */}
      <Sequence from={2 * fps}>
        <Subtitle text="Let's begin" />
      </Sequence>

      {/* Appears at 4 seconds, lasts 3 seconds */}
      <Sequence from={4 * fps} durationInFrames={3 * fps}>
        <CallToAction />
      </Sequence>
    </AbsoluteFill>
  );
};
```

## Media Handling

### Video

```tsx
import { Video } from "@remotion/media";
import { staticFile, useVideoConfig } from "remotion";

export const VideoClip = () => {
  const { fps } = useVideoConfig();

  return (
    <Video
      src={staticFile("clip.mp4")}
      trimBefore={2 * fps}    // Skip first 2 seconds
      trimAfter={10 * fps}    // End at 10 seconds
      volume={0.8}
      playbackRate={1.5}      // 1.5x speed
    />
  );
};
```

### Audio

```tsx
import { Audio } from "@remotion/media";
import { staticFile, interpolate } from "remotion";

export const BackgroundMusic = () => {
  return (
    <Audio
      src={staticFile("music.mp3")}
      volume={(f) => interpolate(f, [0, 30], [0, 0.5], {
        extrapolateRight: 'clamp',
      })}
    />
  );
};
```

### Images

```tsx
import { Img, staticFile } from "remotion";

export const Logo = () => {
  return (
    <Img
      src={staticFile("logo.png")}
      style={{ width: 200, height: 200 }}
    />
  );
};
```

## Detailed Rules

For comprehensive patterns, read the rule files in `tools/video/remotion/`:

| Rule | Purpose |
|------|---------|
| `animations.md` | Fundamental animation patterns |
| `timing.md` | Interpolation, easing, springs |
| `compositions.md` | Defining videos, stills, folders |
| `sequencing.md` | Delay, trim, limit duration |
| `videos.md` | Embedding videos |
| `audio.md` | Sound, volume, trimming |
| `images.md` | Image embedding |
| `fonts.md` | Google Fonts, local fonts |
| `captions.md` | Transcription, subtitles |
| `3d.md` | Three.js integration |
| `transitions.md` | Scene transitions |
| `tailwind.md` | TailwindCSS setup |

## Context7 Integration

For up-to-date API documentation:

```text
/context7 remotion [query]
```

Examples:
- `/context7 remotion spring animation config options`
- `/context7 remotion calculateMetadata dynamic duration`
- `/context7 remotion render video CLI options`

## CLI Commands

```bash
# Start development studio
npx remotion studio

# Render video
npx remotion render src/index.ts MyComposition out/video.mp4

# Render still image
npx remotion still src/index.ts MyStill out/thumbnail.png

# Render with props
npx remotion render src/index.ts MyComposition out/video.mp4 --props='{"title":"Custom"}'
```

## Examples & Inspiration

Open-source Remotion projects to study for patterns and ideas:

| Repository | Description | Key Patterns |
|-----------|-------------|--------------|
| [trycua/launchpad](https://github.com/trycua/launchpad) | Product launch video monorepo (Turborepo + Next.js + Tailwind) | Scene-based architecture, shared packages, scaffolding CLI, word-by-word text animations, code editor scenes, spring physics, sound effects, blur transitions |
| [remotion-dev/trailer](https://github.com/remotion-dev/trailer) | Official Remotion trailer | Advanced compositions, transitions, brand animation |
| [remotion-dev/github-unwrapped](https://github.com/remotion-dev/github-unwrapped) | GitHub Wrapped annual recap videos | Data-driven video, dynamic props, SSR rendering at scale |
| [remotion-dev/template-helloworld](https://github.com/remotion-dev/template-helloworld) | Official starter template | Minimal project structure, basic patterns |

**Architectural patterns from examples:**

- **Scene composition**: Break videos into scene components, each exporting a duration constant (e.g. `INTRO_DURATION = 90`)
- **Shared packages**: Monorepo with reusable animations (`FadeIn`, `SlideUp`, `TextReveal`) and brand assets (colors, fonts, sounds)
- **Constants file**: Centralize `VIDEO_WIDTH`, `VIDEO_HEIGHT`, `VIDEO_FPS` in `types/constants.ts`
- **Scaffolding CLI**: Script to generate new video projects from a template with dimension presets
- **Series composition**: Use `<Series>` to chain scenes sequentially in a `FullVideo` component

## Related

- [Remotion Docs](https://www.remotion.dev/docs)
- [Context7 Remotion](/remotion-dev/remotion)
- `tools/browser/playwright.md` - Browser automation for video assets
