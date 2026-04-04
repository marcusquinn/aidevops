---
name: get-video-dimensions
mode: subagent
description: Getting the width and height of a video file with Mediabunny
metadata:
  tags: dimensions, width, height, resolution, size, video
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Getting video dimensions with Mediabunny

Mediabunny extracts width and height from video files. Works in browser, Node.js, and Bun.

```tsx
import { Input, ALL_FORMATS, UrlSource } from "mediabunny";

export const getVideoDimensions = async (src: string) => {
  const input = new Input({
    formats: ALL_FORMATS,
    source: new UrlSource(src, { getRetryDelay: () => null }),
  });
  const videoTrack = await input.getPrimaryVideoTrack();
  if (!videoTrack) throw new Error("No video track found");
  return { width: videoTrack.displayWidth, height: videoTrack.displayHeight };
};
```

URL or `staticFile`:

```tsx
const { width, height } = await getVideoDimensions("https://remotion.media/video.mp4");
// width: 1920, height: 1080

import { staticFile } from "remotion";
const dims = await getVideoDimensions(staticFile("video.mp4"));
```

## Local files

Use `FileSource` instead of `UrlSource` for `File` objects (input or drag-drop):

```tsx
import { Input, ALL_FORMATS, FileSource } from "mediabunny";

const input = new Input({ formats: ALL_FORMATS, source: new FileSource(file) });
const videoTrack = await input.getPrimaryVideoTrack();
const { displayWidth: width, displayHeight: height } = videoTrack;
```
