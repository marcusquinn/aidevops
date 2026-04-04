---
name: import-srt-captions
mode: subagent
description: Importing .srt subtitle files into Remotion using @remotion/captions
metadata:
  tags: captions, subtitles, srt, import, parse
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Importing .srt subtitles into Remotion

Use `parseSrt()` from `@remotion/captions` to import `.srt` files.

## Install

```bash
npx remotion add @remotion/captions
```

## Usage

`staticFile()` references files in `public/`; remote URLs work via `fetch()`.

```tsx
import {useState, useEffect, useCallback} from 'react';
import {AbsoluteFill, staticFile, useDelayRender} from 'remotion';
import {parseSrt, type Caption} from '@remotion/captions';

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

  useEffect(() => { fetchCaptions(); }, [fetchCaptions]);

  if (!captions) return null;

  return <AbsoluteFill>{/* Use captions here */}</AbsoluteFill>;
};
```
