---
name: get-audio-duration
mode: subagent
description: Getting the duration of an audio file in seconds with Mediabunny
metadata:
  tags: duration, audio, length, time, seconds, mp3, wav
---

# Getting audio duration with Mediabunny

Use `Input.computeDuration()` to get audio length in seconds. This works in browser, Node.js, and Bun.

## URLs and `staticFile()`

```tsx
import { Input, ALL_FORMATS, UrlSource } from "mediabunny";

export const getAudioDuration = async (src: string) => {
  const input = new Input({
    formats: ALL_FORMATS,
    source: new UrlSource(src, {
      getRetryDelay: () => null,
    }),
  });

  const durationInSeconds = await input.computeDuration();
  return durationInSeconds;
};
```

```tsx
import { staticFile } from "remotion";

const remoteDuration = await getAudioDuration("https://remotion.media/audio.mp3");
const staticDuration = await getAudioDuration(staticFile("audio.mp3"));
```

## Local files

Use `FileSource` for browser uploads or drag-and-drop files:

```tsx
import { Input, ALL_FORMATS, FileSource } from "mediabunny";

const input = new Input({
  formats: ALL_FORMATS,
  source: new FileSource(file), // File object from input or drag-drop
});

const durationInSeconds = await input.computeDuration();
```
