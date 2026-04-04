---
name: calculate-metadata
mode: subagent
description: Dynamically set composition duration, dimensions, and props
metadata:
  tags: calculateMetadata, duration, dimensions, props, dynamic
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

`calculateMetadata` runs before render and overrides placeholder `<Composition>` values for duration, dimensions, fps, props, and output defaults. Pass it as the `calculateMetadata` prop on `<Composition>`.

## Set duration from one video

Use `getMediaMetadata()` from the mediabunny/metadata skill when duration depends on the source file.

```tsx
import { CalculateMetadataFunction } from "remotion";
import { getMediaMetadata } from "../get-media-metadata";

const calculateMetadata: CalculateMetadataFunction<Props> = async ({ props }) => {
  const { durationInSeconds } = await getMediaMetadata(props.videoSrc);

  return {
    durationInFrames: Math.ceil(durationInSeconds * 30),
  };
};
```

## Match source dimensions

```tsx
const calculateMetadata: CalculateMetadataFunction<Props> = async ({ props }) => {
  const { durationInSeconds, dimensions } = await getMediaMetadata(props.videoSrc);

  return {
    durationInFrames: Math.ceil(durationInSeconds * 30),
    width: dimensions?.width ?? 1920,
    height: dimensions?.height ?? 1080,
  };
};
```

## Sum multiple videos

```tsx
const calculateMetadata: CalculateMetadataFunction<Props> = async ({ props }) => {
  const allMetadata = await Promise.all(
    props.videos.map((video) => getMediaMetadata(video.src)),
  );

  const totalDuration = allMetadata.reduce(
    (sum, meta) => sum + meta.durationInSeconds,
    0,
  );

  return {
    durationInFrames: Math.ceil(totalDuration * 30),
  };
};
```

## Set `defaultOutName`

```tsx
const calculateMetadata: CalculateMetadataFunction<Props> = async ({ props }) => ({
  defaultOutName: `video-${props.id}.mp4`,
});
```

## Transform props before render

`abortSignal` cancels stale Studio requests when props change.

```tsx
const calculateMetadata: CalculateMetadataFunction<Props> = async ({
  props,
  abortSignal,
}) => {
  const response = await fetch(props.dataUrl, { signal: abortSignal });
  const data = await response.json();

  return {
    props: {
      ...props,
      fetchedData: data,
    },
  };
};
```

## Return fields

All fields are optional and override the `<Composition>` props.

| Field | Description |
|-------|-------------|
| `durationInFrames` | Frame count |
| `width` | Composition width in pixels |
| `height` | Composition height in pixels |
| `fps` | Frames per second |
| `props` | Transformed props passed to the component |
| `defaultOutName` | Default output filename |
| `defaultCodec` | Default codec for rendering |
