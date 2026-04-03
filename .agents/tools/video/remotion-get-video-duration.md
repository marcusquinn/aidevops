---
name: get-video-duration
mode: subagent
description: Getting the duration of a video file in seconds with Mediabunny
metadata:
  tags: duration, video, length, time, seconds
---

# Getting video duration with Mediabunny

Use `Input.computeDuration()` to get duration in seconds. Works in browser, Node.js, and Bun.

## URL source

```tsx
import { Input, ALL_FORMATS, UrlSource } from "mediabunny";

export const getVideoDuration = async (src: string) => {
  const input = new Input({
    formats: ALL_FORMATS,
    source: new UrlSource(src, { getRetryDelay: () => null }),
  });
  return await input.computeDuration();
};
```

Use with Remotion `staticFile()`: `getVideoDuration(staticFile("video.mp4"))`

## Local file source

```tsx
import { Input, ALL_FORMATS, FileSource } from "mediabunny";

const input = new Input({
  formats: ALL_FORMATS,
  source: new FileSource(file), // File object from input or drag-drop
});
const durationInSeconds = await input.computeDuration();
```
