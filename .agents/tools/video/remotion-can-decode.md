---
name: can-decode
mode: subagent
description: Check if a video can be decoded by the browser using Mediabunny
metadata:
  tags: decode, video, audio, mediabunny, canDecode, browser, compatibility
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Checking if a video can be decoded

Use `canDecode()` from Mediabunny to check browser decode support before playback.

## Shared helper

```tsx
import { Input, ALL_FORMATS } from "mediabunny";

const checkTracks = async (input: Input): Promise<boolean> => {
  try {
    await input.getFormat();
  } catch {
    return false;
  }

  const videoTrack = await input.getPrimaryVideoTrack();
  if (videoTrack && !(await videoTrack.canDecode())) return false;

  const audioTrack = await input.getPrimaryAudioTrack();
  if (audioTrack && !(await audioTrack.canDecode())) return false;

  return true;
};
```

## URL source

```tsx
import { UrlSource } from "mediabunny";

export const canDecode = (src: string) =>
  checkTracks(new Input({ formats: ALL_FORMATS, source: new UrlSource(src, { getRetryDelay: () => null }) }));

const isDecodable = await canDecode("https://remotion.media/video.mp4");
```

## Blob source (file uploads / drag-and-drop)

```tsx
import { BlobSource } from "mediabunny";

export const canDecodeBlob = (blob: Blob) =>
  checkTracks(new Input({ formats: ALL_FORMATS, source: new BlobSource(blob) }));
```
