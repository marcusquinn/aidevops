---
name: audio
mode: subagent
description: Using audio and sound in Remotion - importing, trimming, volume, speed, pitch
metadata:
  tags: audio, media, trim, volume, speed, loop, pitch, mute, sound, sfx
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Using audio in Remotion

## Prerequisites

Install `@remotion/media`:

```bash
npx remotion add @remotion/media  # npm
bunx remotion add @remotion/media  # bun
yarn remotion add @remotion/media  # yarn
pnpm exec remotion add @remotion/media  # pnpm
```

## Importing Audio

```tsx
import { Audio } from "@remotion/media";
import { staticFile } from "remotion";

export const MyComposition = () => {
  return <Audio src={staticFile("audio.mp3")} />;
};
```

Remote URLs are also supported: `<Audio src="https://remotion.media/audio.mp3" />`

Defaults: plays from start, full volume, full length. Layer multiple tracks with multiple `<Audio>` components.

## Trimming

`trimBefore` and `trimAfter` take frame values. The trimmed portion plays from the composition start.

```tsx
const { fps } = useVideoConfig();

return (
  <Audio
    src={staticFile("audio.mp3")}
    trimBefore={2 * fps}  // Skip first 2s
    trimAfter={10 * fps}  // End at 10s mark
  />
);
```

## Delaying

Wrap in `<Sequence>` to delay playback:

```tsx
import { Sequence, staticFile } from "remotion";
import { Audio } from "@remotion/media";

const { fps } = useVideoConfig();

return (
  <Sequence from={1 * fps}>
    <Audio src={staticFile("audio.mp3")} />
  </Sequence>
);
```

## Volume

Static (0–1):

```tsx
<Audio src={staticFile("audio.mp3")} volume={0.5} />
```

Dynamic via callback — `f` starts at 0 when audio begins, not at the composition frame:

```tsx
import { interpolate } from "remotion";

const { fps } = useVideoConfig();

return (
  <Audio
    src={staticFile("audio.mp3")}
    volume={(f) =>
      interpolate(f, [0, 1 * fps], [0, 1], { extrapolateRight: "clamp" })
    }
  />
);
```

## Muting

`muted` can be set dynamically:

```tsx
const frame = useCurrentFrame();
const { fps } = useVideoConfig();

return (
  <Audio
    src={staticFile("audio.mp3")}
    muted={frame >= 2 * fps && frame <= 4 * fps}  // Mute 2s–4s
  />
);
```

## Speed

```tsx
<Audio src={staticFile("audio.mp3")} playbackRate={2} />    // 2x
<Audio src={staticFile("audio.mp3")} playbackRate={0.5} />  // 0.5x
```

Reverse playback is not supported.

## Looping

```tsx
<Audio src={staticFile("audio.mp3")} loop />
```

`loopVolumeCurveBehavior` controls frame count on loop:

- `"repeat"` (default): resets to 0 each loop
- `"extend"`: continues incrementing

```tsx
<Audio
  src={staticFile("audio.mp3")}
  loop
  loopVolumeCurveBehavior="extend"
  volume={(f) => interpolate(f, [0, 300], [1, 0])}  // Fade out over multiple loops
/>
```

## Pitch

`toneFrequency` adjusts pitch without affecting speed (range: 0.01–2). Only works during server-side rendering — not in Remotion Studio preview or `<Player />`.

```tsx
<Audio src={staticFile("audio.mp3")} toneFrequency={1.5} />  // Higher pitch
<Audio src={staticFile("audio.mp3")} toneFrequency={0.8} />  // Lower pitch
```
