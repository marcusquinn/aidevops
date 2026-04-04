---
name: assets
mode: subagent
description: Importing images, videos, audio, and fonts into Remotion
metadata:
  tags: assets, staticFile, images, fonts, public
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Importing assets in Remotion

## Local assets: `public/` + `staticFile()`

Place assets in `public/` and reference with `staticFile()`. Returns an encoded URL that handles subdirectory deployments and filenames with `#`, `?`, `&`.

```tsx
import {Img, staticFile} from 'remotion';
import {Video, Audio} from '@remotion/media';

<Img src={staticFile('photo.png')} />;
<Video src={staticFile('clip.mp4')} />;
<Audio src={staticFile('music.mp3')} />;
```

For fonts:

```tsx
import {staticFile} from 'remotion';

const fontFamily = new FontFace('MyFont', `url(${staticFile('font.woff2')})`);
await fontFamily.load();
document.fonts.add(fontFamily);
```

## Remote URLs

Pass remote URLs directly without `staticFile()`:

```tsx
<Img src="https://example.com/image.png" />
<Video src="https://remotion.media/video.mp4" />
```

## Why use Remotion components

Remotion components (`<Img>`, `<Video>`, `<Audio>`) ensure assets are fully loaded before rendering.
