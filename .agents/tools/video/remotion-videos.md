---
name: videos
mode: subagent
description: Embedding videos in Remotion - trimming, volume, speed, looping, pitch
metadata:
  tags: video, media, trim, volume, speed, loop, pitch
---

# Using videos in Remotion

## Prerequisites

Install `@remotion/media` if not already present:

```bash
npx remotion add @remotion/media # npm
bunx remotion add @remotion/media # bun
yarn remotion add @remotion/media # yarn
pnpm exec remotion add @remotion/media # pnpm
```

`<Video>` from `@remotion/media` embeds videos into compositions:

```tsx
import { Video } from "@remotion/media";
import { staticFile } from "remotion";

export const MyComposition = () => {
  return <Video src={staticFile("video.mp4")} />;
};
```

Remote URLs are supported: `<Video src="https://remotion.media/video.mp4" />`

## Trimming

`trimBefore` / `trimAfter` remove portions of the video (values in seconds):

```tsx
const { fps } = useVideoConfig();

return (
  <Video
    src={staticFile("video.mp4")}
    trimBefore={2 * fps} // Skip the first 2 seconds
    trimAfter={10 * fps} // End at the 10 second mark
  />
);
```

## Delaying

Wrap in `<Sequence>` to delay appearance:

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
  style={{
    width: 500,
    height: 300,
    position: "absolute",
    top: 100,
    left: 50,
    objectFit: "cover",
  }}
/>
```

## Volume

Static volume (0 to 1):

```tsx
<Video src={staticFile("video.mp4")} volume={0.5} />
```

Dynamic volume via callback (receives current frame):

```tsx
import { interpolate } from "remotion";

const { fps } = useVideoConfig();

return (
  <Video
    src={staticFile("video.mp4")}
    volume={(f) =>
      interpolate(f, [0, 1 * fps], [0, 1], { extrapolateRight: "clamp" })
    }
  />
);
```

Mute entirely: `<Video src={staticFile("video.mp4")} muted />`

## Speed

`playbackRate` controls playback speed:

```tsx
<Video src={staticFile("video.mp4")} playbackRate={2} /> {/* 2x speed */}
<Video src={staticFile("video.mp4")} playbackRate={0.5} /> {/* Half speed */}
```

Reverse playback is not supported.

## Looping

`loop` loops the video indefinitely:

```tsx
<Video src={staticFile("video.mp4")} loop />
```

`loopVolumeCurveBehavior` controls frame count behaviour when looping:

- `"repeat"`: Frame count resets to 0 each loop (for `volume` callback)
- `"extend"`: Frame count continues incrementing

```tsx
<Video
  src={staticFile("video.mp4")}
  loop
  loopVolumeCurveBehavior="extend"
  volume={(f) => interpolate(f, [0, 300], [1, 0])} // Fade out over multiple loops
/>
```

## Pitch

`toneFrequency` adjusts pitch without affecting speed (range: 0.01–2):

```tsx
<Video
  src={staticFile("video.mp4")}
  toneFrequency={1.5} // Higher pitch
/>
<Video
  src={staticFile("video.mp4")}
  toneFrequency={0.8} // Lower pitch
/>
```

Pitch shifting only works during server-side rendering, not in the Remotion Studio preview or in the `<Player />`.
