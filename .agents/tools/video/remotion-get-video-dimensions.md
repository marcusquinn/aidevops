---
name: get-video-dimensions
mode: subagent
description: Getting the width and height of a video file with Mediabunny
metadata:
  tags: dimensions, width, height, resolution, size, video
---

# Getting video dimensions with Mediabunny

Mediabunny extracts width and height from video files. Works in browser, Node.js, and Bun.

```tsx
import { Input, ALL_FORMATS, UrlSource } from "mediabunny";

export const getVideoDimensions = async (src: string) => {
  const input = new Input({
    formats: ALL_FORMATS,
    source: new UrlSource(src, {
      getRetryDelay: () => null,
    }),
  });

  const videoTrack = await input.getPrimaryVideoTrack();
  if (!videoTrack) {
    throw new Error("No video track found");
  }

  return {
    width: videoTrack.displayWidth,
    height: videoTrack.displayHeight,
  };
};

// Usage
const dimensions = await getVideoDimensions("https://remotion.media/video.mp4");
console.log(dimensions.width);  // e.g. 1920
console.log(dimensions.height); // e.g. 1080

// With staticFile in Remotion
import { staticFile } from "remotion";
const dims = await getVideoDimensions(staticFile("video.mp4"));
```

## Local files

Use `FileSource` instead of `UrlSource` for `File` objects (input or drag-drop):

```tsx
import { Input, ALL_FORMATS, FileSource } from "mediabunny";

const input = new Input({
  formats: ALL_FORMATS,
  source: new FileSource(file),
});

const videoTrack = await input.getPrimaryVideoTrack();
const width = videoTrack.displayWidth;
const height = videoTrack.displayHeight;
```
