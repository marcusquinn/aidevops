---
name: gif
mode: subagent
description: Displaying GIFs, APNG, AVIF and WebP in Remotion
metadata:
  tags: gif, animation, images, animated, apng, avif, webp
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Animated Images in Remotion

## Basic Usage

`<AnimatedImage>` displays GIF, APNG, AVIF or WebP synchronized with Remotion's timeline:

```tsx
import {AnimatedImage, staticFile} from 'remotion';

export const MyComposition = () => {
  return <AnimatedImage src={staticFile('animation.gif')} width={500} height={500} />;
};
```

Remote URLs also work (must have CORS enabled):

```tsx
<AnimatedImage src="https://example.com/animation.gif" width={500} height={500} />
```

## Props

### `fit` — sizing behavior

```tsx
<AnimatedImage src={staticFile("animation.gif")} width={500} height={300} fit="fill" />    {/* Stretch (default) */}
<AnimatedImage src={staticFile("animation.gif")} width={500} height={300} fit="contain" />  {/* Fit inside, keep ratio */}
<AnimatedImage src={staticFile("animation.gif")} width={500} height={300} fit="cover" />    {/* Fill, crop if needed */}
```

### `playbackRate` — animation speed

```tsx
<AnimatedImage src={staticFile("animation.gif")} width={500} height={500} playbackRate={2} />   {/* 2x speed */}
<AnimatedImage src={staticFile("animation.gif")} width={500} height={500} playbackRate={0.5} /> {/* Half speed */}
```

### `loopBehavior` — end-of-animation behavior

```tsx
<AnimatedImage src={staticFile("animation.gif")} width={500} height={500} loopBehavior="loop" />                {/* Loop indefinitely (default) */}
<AnimatedImage src={staticFile("animation.gif")} width={500} height={500} loopBehavior="pause-after-finish" />  {/* Play once, show final frame */}
<AnimatedImage src={staticFile("animation.gif")} width={500} height={500} loopBehavior="clear-after-finish" />  {/* Play once, clear canvas */}
```

### `style` — additional CSS

Use `width`/`height` props for sizing; `style` for positioning and decoration:

```tsx
<AnimatedImage
  src={staticFile('animation.gif')}
  width={500}
  height={500}
  style={{borderRadius: 20, position: 'absolute', top: 100, left: 50}}
/>
```

## Getting GIF Duration

Requires `@remotion/gif`:

```bash
npx remotion add @remotion/gif    # npm
bunx remotion add @remotion/gif   # bun
yarn remotion add @remotion/gif   # yarn
pnpm exec remotion add @remotion/gif  # pnpm
```

```tsx
import {getGifDurationInSeconds} from '@remotion/gif';
import {staticFile, CalculateMetadataFunction} from 'remotion';

// Standalone usage
const duration = await getGifDurationInSeconds(staticFile('animation.gif'));
console.log(duration); // e.g. 2.5

// Match composition duration to GIF length
const calculateMetadata: CalculateMetadataFunction = async () => {
  const duration = await getGifDurationInSeconds(staticFile('animation.gif'));
  return {durationInFrames: Math.ceil(duration * 30)};
};
```

## Fallback: `<Gif>` Component

If `<AnimatedImage>` doesn't work (requires Chrome or Firefox), use `<Gif>` from `@remotion/gif` (same install as above). Same props as `<AnimatedImage>` but only supports GIF files:

```tsx
import {Gif} from '@remotion/gif';
import {staticFile} from 'remotion';

export const MyComposition = () => {
  return <Gif src={staticFile('animation.gif')} width={500} height={500} />;
};
```
