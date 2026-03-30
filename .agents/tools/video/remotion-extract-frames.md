---
name: extract-frames
mode: subagent
description: Extract frames from videos at specific timestamps using Mediabunny
metadata:
  tags: frames, extract, video, thumbnail, filmstrip, canvas
---

# Extracting frames from videos

Use [Mediabunny](https://mediabunny.dev) to extract frames at specific timestamps. Useful for thumbnails, filmstrips, and per-frame processing.

## API

### `extractFrames(props)` — copy-paste into any project

| Prop | Type | Required | Description |
|------|------|----------|-------------|
| `src` | `string` | Yes | Video URL |
| `timestampsInSeconds` | `number[]` \| `(opts) => Promise<number[]>` | Yes | Fixed list or callback receiving `{track, container, durationInSeconds}` |
| `onVideoSample` | `(sample: VideoSample) => void` | Yes | Called for each decoded frame |
| `signal` | `AbortSignal` | No | Cancel in-flight extraction |

```tsx
import {
  ALL_FORMATS,
  Input,
  UrlSource,
  VideoSample,
  VideoSampleSink,
} from "mediabunny";

export async function extractFrames({
  src,
  timestampsInSeconds,
  onVideoSample,
  signal,
}: ExtractFramesProps): Promise<void> {
  using input = new Input({
    formats: ALL_FORMATS,
    source: new UrlSource(src),
  });

  const [durationInSeconds, format, videoTrack] = await Promise.all([
    input.computeDuration(),
    input.getFormat(),
    input.getPrimaryVideoTrack(),
  ]);

  if (!videoTrack) throw new Error("No video track found in the input");
  if (signal?.aborted) throw new Error("Aborted");

  const timestamps =
    typeof timestampsInSeconds === "function"
      ? await timestampsInSeconds({
          track: { width: videoTrack.displayWidth, height: videoTrack.displayHeight },
          container: format.name,
          durationInSeconds,
        })
      : timestampsInSeconds;

  if (timestamps.length === 0) return;
  if (signal?.aborted) throw new Error("Aborted");

  const sink = new VideoSampleSink(videoTrack);

  for await (using videoSample of sink.samplesAtTimestamps(timestamps)) {
    if (signal?.aborted) break;
    if (!videoSample) continue;
    onVideoSample(videoSample);
  }
}
```

## Basic usage

```tsx
await extractFrames({
  src: "https://remotion.media/video.mp4",
  timestampsInSeconds: [0, 1, 2, 3, 4],
  onVideoSample: (sample) => {
    const canvas = document.createElement("canvas");
    canvas.width = sample.displayWidth;
    canvas.height = sample.displayHeight;
    const ctx = canvas.getContext("2d");
    sample.draw(ctx!, 0, 0);
  },
});
```

## Filmstrip (dynamic timestamps via callback)

Pass a callback to `timestampsInSeconds` to compute timestamps from video metadata:

```tsx
const canvasWidth = 500;
const canvasHeight = 80;
const fromSeconds = 0;
const toSeconds = 10;

await extractFrames({
  src: "https://remotion.media/video.mp4",
  timestampsInSeconds: async ({ track }) => {
    const aspectRatio = track.width / track.height;
    const amountOfFramesFit = Math.ceil(canvasWidth / (canvasHeight * aspectRatio));
    const segmentDuration = toSeconds - fromSeconds;
    const timestamps: number[] = [];
    for (let i = 0; i < amountOfFramesFit; i++) {
      timestamps.push(fromSeconds + (segmentDuration / amountOfFramesFit) * (i + 0.5));
    }
    return timestamps;
  },
  onVideoSample: (sample) => {
    // Render to canvas (see Basic usage above)
    sample.draw(document.createElement("canvas").getContext("2d")!, 0, 0);
  },
});
```

## Cancellation and timeout

Pass `signal` for cancellation. For simple timeout: `setTimeout(() => controller.abort(), ms)`. For racing with a cleanup-safe timeout:

```tsx
const controller = new AbortController();

const timeoutPromise = new Promise<never>((_, reject) => {
  const timeoutId = setTimeout(() => {
    controller.abort();
    reject(new Error("Frame extraction timed out after 10 seconds"));
  }, 10000);
  controller.signal.addEventListener("abort", () => clearTimeout(timeoutId), { once: true });
});

try {
  await Promise.race([
    extractFrames({
      src: "https://remotion.media/video.mp4",
      timestampsInSeconds: [0, 1, 2, 3, 4],
      onVideoSample: (sample) => {
        sample.draw(document.createElement("canvas").getContext("2d")!, 0, 0);
      },
      signal: controller.signal,
    }),
    timeoutPromise,
  ]);
} catch (error) {
  console.error("Frame extraction was aborted or failed:", error);
}
```
