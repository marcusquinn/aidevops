---
name: videos
mode: subagent
description: Embedding videos in Remotion - trimming, volume, speed, looping, pitch
metadata:
  tags: video, media, trim, volume, speed, loop, pitch
---

# Using videos in Remotion

## Setup

Install and import:

```bash
npx remotion add @remotion/media  # npm; use bunx / yarn dlx / pnpm dlx for others
```

```tsx
import { Video } from "@remotion/media";
import { staticFile } from "remotion";

export const MyComposition = () => <Video src={staticFile("video.mp4")} />;
```

Remote URLs: `<Video src="https://remotion.media/video.mp4" />`

## Trimming

`trimBefore` / `trimAfter` (values in frames):

```tsx
const { fps } = useVideoConfig();
return (
  <Video
    src={staticFile("video.mp4")}
    trimBefore={2 * fps}  // skip first 2s
    trimAfter={10 * fps}  // end at 10s
  />
);
```

## Delaying

Wrap in `<Sequence>`:

```tsx
import { Sequence, staticFile } from "remotion";
import { Video } from "@remotion/media";

const { fps } = useVideoConfig();
return (
  <Sequence from={1 * fps}>
    <Video src={staticFile("video.mp4")} />
  </Sequence>
);
```

## Sizing and Position

Use the `style` prop:

```tsx
<Video
  src={staticFile("video.mp4")}
  style={{ width: 500, height: 300, position: "absolute", top: 100, left: 50, objectFit: "cover" }}
/>
```

## Volume

```tsx
<Video src={staticFile("video.mp4")} volume={0.5} />  {/* 0–1 */}
<Video src={staticFile("video.mp4")} muted />
```

Dynamic (fade in over 1s):

```tsx
import { interpolate } from "remotion";
const { fps } = useVideoConfig();
return (
  <Video
    src={staticFile("video.mp4")}
    volume={(f) => interpolate(f, [0, 1 * fps], [0, 1], { extrapolateRight: "clamp" })}
  />
);
```

## Speed

```tsx
<Video src={staticFile("video.mp4")} playbackRate={2} />    {/* 2× */}
<Video src={staticFile("video.mp4")} playbackRate={0.5} />  {/* 0.5× */}
```

Reverse playback is not supported.

## Looping

```tsx
<Video src={staticFile("video.mp4")} loop />
```

`loopVolumeCurveBehavior` controls frame count for the `volume` callback:

- `"repeat"` (default): resets to 0 each loop
- `"extend"`: continues incrementing

```tsx
<Video
  src={staticFile("video.mp4")}
  loop
  loopVolumeCurveBehavior="extend"
  volume={(f) => interpolate(f, [0, 300], [1, 0])}
/>
```

## Pitch

`toneFrequency` adjusts pitch without affecting speed (range: 0.01–2):

```tsx
<Video src={staticFile("video.mp4")} toneFrequency={1.5} />  {/* higher */}
<Video src={staticFile("video.mp4")} toneFrequency={0.8} />  {/* lower */}
```

Pitch shifting only works during server-side rendering, not in Remotion Studio or `<Player />`.
