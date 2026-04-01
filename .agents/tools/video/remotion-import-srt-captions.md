---
name: import-srt-captions
mode: subagent
description: Importing .srt subtitle files into Remotion using @remotion/captions
metadata:
  tags: captions, subtitles, srt, import, parse
---

# Importing .srt subtitles into Remotion

Use `parseSrt()` from `@remotion/captions` to import `.srt` files.

## Install

```bash
npx remotion add @remotion/captions  # npm
bunx remotion add @remotion/captions  # bun
yarn remotion add @remotion/captions  # yarn
pnpm exec remotion add @remotion/captions  # pnpm
```

## Usage

`staticFile()` references files in `public/`; remote URLs work via `fetch()` directly.

```tsx
import {useState, useEffect, useCallback} from 'react';
import {AbsoluteFill, staticFile, useDelayRender} from 'remotion';
import {parseSrt} from '@remotion/captions';
import type {Caption} from '@remotion/captions';

export const MyComponent: React.FC = () => {
  const [captions, setCaptions] = useState<Caption[] | null>(null);
  const {delayRender, continueRender, cancelRender} = useDelayRender();
  const [handle] = useState(() => delayRender());

  const fetchCaptions = useCallback(async () => {
    try {
      const response = await fetch(staticFile('subtitles.srt'));
      const text = await response.text();
      const {captions: parsed} = parseSrt({input: text});
      setCaptions(parsed);
      continueRender(handle);
    } catch (e) {
      cancelRender(e);
    }
  }, [continueRender, cancelRender, handle]);

  useEffect(() => {
    fetchCaptions();
  }, [fetchCaptions]);

  if (!captions) {
    return null;
  }

  // captions: Caption[] — use with all @remotion/captions utilities
  return <AbsoluteFill>{/* Use captions here */}</AbsoluteFill>;
};
```
