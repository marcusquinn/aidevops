---
name: calculate-metadata
mode: subagent
description: Dynamically set composition duration, dimensions, and props
metadata:
  tags: calculateMetadata, duration, dimensions, props, dynamic
---

`calculateMetadata` runs before render and can override placeholder `<Composition>` values for duration, dimensions, fps, props, and output defaults.

```tsx
<Composition
  id="MyComp"
  component={MyComponent}
  durationInFrames={300}
  fps={30}
  width={1920}
  height={1080}
  defaultProps={{ videoSrc: "https://remotion.media/video.mp4" }}
  calculateMetadata={calculateMetadata}
/>
```

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

`abortSignal` cancels stale Studio requests when props change.

## Return fields

All fields are optional. Returned values override the `<Composition>` props.

- `durationInFrames`: frame count
- `width`: composition width in pixels
- `height`: composition height in pixels
- `fps`: frames per second
- `props`: transformed props passed to the component
- `defaultOutName`: default output filename
- `defaultCodec`: default codec for rendering
