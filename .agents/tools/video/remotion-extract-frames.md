---
name: extract-frames
mode: subagent
description: Extract frames from videos at specific timestamps using Mediabunny
metadata:
  tags: frames, extract, video, thumbnail, filmstrip, canvas
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Extracting frames from videos

Use [Mediabunny](https://mediabunny.dev) to extract frames at specific timestamps for thumbnails, filmstrips, and per-frame processing.

## API

| Prop | Type | Required | Description |
|------|------|----------|-------------|
| `src` | `string` | Yes | Video URL |
| `timestampsInSeconds` | `number[]` \| `(opts) => Promise<number[]>` | Yes | Fixed list or callback receiving `{track, container, durationInSeconds}` |
| `onVideoSample` | `(sample: VideoSample) => void` | Yes | Called for each decoded frame |
| `signal` | `AbortSignal` | No | Cancel in-flight extraction |

## Implementation

```tsx
import { ALL_FORMATS, Input, UrlSource, VideoSample, VideoSampleSink } from "mediabunny";

export async function extractFrames({
  src, timestampsInSeconds, onVideoSample, signal,
}: ExtractFramesProps): Promise<void> {
  using input = new Input({ formats: ALL_FORMATS, source: new UrlSource(src) });

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
    sample.draw(canvas.getContext("2d")!, 0, 0);
  },
});
```

## Filmstrip (dynamic timestamps)

Use a callback when timestamps depend on video metadata:

```tsx
await extractFrames({
  src: "https://remotion.media/video.mp4",
  timestampsInSeconds: async ({ track }) => {
    const aspectRatio = track.width / track.height;
    const count = Math.ceil(500 / (80 * aspectRatio)); // canvasWidth / (canvasHeight * aspect)
    return Array.from({ length: count }, (_, i) => (10 / count) * (i + 0.5)); // 0–10s range
  },
  onVideoSample: (sample) => {
    sample.draw(document.createElement("canvas").getContext("2d")!, 0, 0);
  },
});
```

## Cancellation and timeout

Pass `signal` to support cancellation. Race against a timeout promise:

```tsx
const controller = new AbortController();
setTimeout(() => controller.abort(), 10000);

try {
  await extractFrames({
    src: "https://remotion.media/video.mp4",
    timestampsInSeconds: [0, 1, 2, 3, 4],
    onVideoSample: (sample) => {
      sample.draw(document.createElement("canvas").getContext("2d")!, 0, 0);
    },
    signal: controller.signal,
  });
} catch (error) {
  console.error("Frame extraction was aborted or failed:", error);
}
```
