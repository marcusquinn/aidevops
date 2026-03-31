---
name: assets
mode: subagent
description: Importing images, videos, audio, and fonts into Remotion
metadata:
  tags: assets, staticFile, images, fonts, public
---

# Importing assets in Remotion

## Local assets: `public/` + `staticFile()`

Place project assets in `public/` and reference them with `staticFile()`. It returns an encoded URL that keeps local asset paths working, including deployments under subdirectories and filenames with characters like `#`, `?`, and `&`.

```tsx
import {Img, staticFile} from 'remotion';

export const MyComposition = () => {
  return <Img src={staticFile('logo.png')} />;
};
```

## Supported asset types

Use `staticFile()` for local images, videos, audio, and fonts:

```tsx
import {Img, staticFile} from 'remotion';
import {Video, Audio} from '@remotion/media';

<Img src={staticFile('photo.png')} />;
<Video src={staticFile('clip.mp4')} />;
<Audio src={staticFile('music.mp3')} />;
```

For fonts, load the file URL returned by `staticFile()`:

```tsx
import {staticFile} from 'remotion';

const fontFamily = new FontFace('MyFont', `url(${staticFile('font.woff2')})`);
await fontFamily.load();
document.fonts.add(fontFamily);
```

## Remote URLs

Remote URLs can be passed directly without `staticFile()`:

```tsx
<Img src="https://example.com/image.png" />
<Video src="https://remotion.media/video.mp4" />
```

## Why use Remotion components

- Remotion components (`<Img>`, `<Video>`, `<Audio>`) ensure assets are fully loaded before rendering
