---
name: compositions
mode: subagent
description: Defining compositions, stills, folders, default props and dynamic metadata
metadata:
  tags: composition, still, folder, props, metadata
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

`<Composition>` defines component, dimensions, fps and duration for a renderable video. Place in `src/Root.tsx`.

```tsx
// src/Root.tsx
import { Composition } from "remotion";
import { MyComposition } from "./MyComposition";

export const RemotionRoot = () => (
  <Composition
    id="MyComposition"
    component={MyComposition}
    durationInFrames={100}
    fps={30}
    width={1080}
    height={1080}
  />
);
```

## Default Props

`defaultProps` provides initial values. Must be JSON-serializable (`Date`, `Map`, `Set`, `staticFile()` supported). Use `type` (not `interface`) for props to ensure type safety with `satisfies`.

```tsx
<Composition
  id="MyComposition"
  component={MyComposition}
  durationInFrames={100}
  fps={30}
  width={1080}
  height={1080}
  defaultProps={{
    title: "Hello World",
    color: "#ff0000",
  } satisfies MyCompositionProps}
/>
```

## Folders

`<Folder>` organizes compositions in the sidebar. Names: letters, numbers, hyphens only. Supports nesting.

```tsx
import { Composition, Folder } from "remotion";

<>
  <Folder name="Marketing">
    <Composition id="Promo" /* ... */ />
    <Composition id="Ad" /* ... */ />
  </Folder>
  <Folder name="Social">
    <Folder name="Instagram">
      <Composition id="Story" /* ... */ />
      <Composition id="Reel" /* ... */ />
    </Folder>
  </Folder>
</>
```

## Stills

`<Still>` renders single-frame images. No `durationInFrames` or `fps` required.

```tsx
import { Still } from "remotion";

<Still id="Thumbnail" component={Thumbnail} width={1280} height={720} />
```

## Calculate Metadata

`calculateMetadata` makes dimensions, duration, or props dynamic. Runs once before rendering. Can return `props`, `durationInFrames`, `width`, `height`, `fps`, and codec defaults.

```tsx
import { Composition, CalculateMetadataFunction } from "remotion";
import { MyComposition, MyCompositionProps } from "./MyComposition";

const calculateMetadata: CalculateMetadataFunction<MyCompositionProps> = async ({
  props,
  abortSignal,
}) => {
  const data = await fetch(`https://api.example.com/video/${props.videoId}`, {
    signal: abortSignal,
  }).then((res) => res.json());

  return {
    durationInFrames: Math.ceil(data.duration * 30),
    props: { ...props, videoUrl: data.url },
  };
};

export const RemotionRoot = () => (
  <Composition
    id="MyComposition"
    component={MyComposition}
    durationInFrames={100} // Placeholder, will be overridden
    fps={30}
    width={1080}
    height={1080}
    defaultProps={{ videoId: "abc123" }}
    calculateMetadata={calculateMetadata}
  />
);
```
