---
name: images
mode: subagent
description: Embedding images in Remotion using the <Img> component
metadata:
  tags: images, img, staticFile, png, jpg, svg, webp
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Using images in Remotion

## The `<Img>` component

Always use `<Img>` from `remotion` — not native `<img>`, Next.js `<Image>`, or CSS `background-image`. It ensures images are fully loaded before rendering, preventing blank frames.

```tsx
import { Img, staticFile } from "remotion";

export const MyComposition = () => {
  return <Img src={staticFile("photo.png")} />;
};
```

## Local images with staticFile()

Place images in `public/` and reference with `staticFile()`:

```text
my-video/
├─ public/
│  ├─ logo.png
│  ├─ avatar.jpg
│  └─ icon.svg
```

```tsx
<Img src={staticFile("logo.png")} />
```

## Remote images

```tsx
<Img src="https://example.com/image.png" />
```

Ensure remote images have CORS enabled. For animated GIFs, use `<Gif>` from `@remotion/gif` instead.

## Sizing and positioning

```tsx
<Img
  src={staticFile("photo.png")}
  style={{
    width: 500,
    height: 300,
    position: "absolute",
    top: 100,
    left: 50,
    objectFit: "cover",
  }}
/>
```

## Dynamic image paths

Use template literals for dynamic file references:

```tsx
import { Img, staticFile, useCurrentFrame } from "remotion";

const frame = useCurrentFrame();

// Image sequence
<Img src={staticFile(`frames/frame${frame}.png`)} />

// Selecting based on props
<Img src={staticFile(`avatars/${props.userId}.png`)} />

// Conditional images
<Img src={staticFile(`icons/${isActive ? "active" : "inactive"}.svg`)} />
```

## Getting image dimensions

```tsx
import { getImageDimensions, staticFile, CalculateMetadataFunction } from "remotion";

const calculateMetadata: CalculateMetadataFunction = async () => {
  const { width, height } = await getImageDimensions(staticFile("photo.png"));
  return { width, height };
};
```
