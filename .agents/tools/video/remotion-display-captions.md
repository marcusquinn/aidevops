---
name: display-captions
mode: subagent
description: Displaying captions in Remotion with TikTok-style pages and word highlighting
metadata:
  tags: captions, subtitles, display, tiktok, highlight
---

# Displaying captions in Remotion

Display `Caption[]` data with TikTok-style pages and per-word highlighting.

## Install

```bash
npx remotion add @remotion/captions  # npm
bunx remotion add @remotion/captions  # bun
yarn remotion add @remotion/captions  # yarn
pnpm exec remotion add @remotion/captions  # pnpm
```

## 1. Group captions into pages

`createTikTokStyleCaptions()` batches words into timed pages. `combineTokensWithinMilliseconds` controls page duration — higher = more words per page.

```tsx
import {useMemo} from 'react';
import {createTikTokStyleCaptions} from '@remotion/captions';
import type {Caption} from '@remotion/captions';

const SWITCH_CAPTIONS_EVERY_MS = 1200;

const CaptionedContent: React.FC<{captions: Caption[]}> = ({captions}) => {
  const {pages} = useMemo(() => {
    return createTikTokStyleCaptions({
      captions,
      combineTokensWithinMilliseconds: SWITCH_CAPTIONS_EVERY_MS,
    });
  }, [captions]);
};
```

## 2. Render each page in a `<Sequence>`

Map over `pages`, derive frame timing from `startMs`, render each in a bounded `<Sequence>`.

```tsx
import {Sequence, useVideoConfig, AbsoluteFill} from 'remotion';
import type {TikTokPage} from '@remotion/captions';

const CaptionedContent: React.FC<{pages: TikTokPage[]}> = ({pages}) => {
  const {fps} = useVideoConfig();

  return (
    <AbsoluteFill>
      {pages.map((page, index) => {
        const nextPage = pages[index + 1] ?? null;
        const startFrame = (page.startMs / 1000) * fps;
        const endFrame = Math.min(
          nextPage ? (nextPage.startMs / 1000) * fps : Infinity,
          startFrame + (SWITCH_CAPTIONS_EVERY_MS / 1000) * fps,
        );
        const durationInFrames = endFrame - startFrame;

        if (durationInFrames <= 0) {
          return null;
        }

        return (
          <Sequence
            key={index}
            from={startFrame}
            durationInFrames={durationInFrames}
          >
            <CaptionPage page={page} />
          </Sequence>
        );
      })}
    </AbsoluteFill>
  );
};
```

## 3. Highlight the active word

Each page exposes `tokens` with `fromMs`/`toMs` bounds. Compare against current playback time to highlight the active token.

```tsx
import {AbsoluteFill, useCurrentFrame, useVideoConfig} from 'remotion';
import type {TikTokPage} from '@remotion/captions';

const HIGHLIGHT_COLOR = '#39E508';

const CaptionPage: React.FC<{page: TikTokPage}> = ({page}) => {
  const frame = useCurrentFrame();
  const {fps} = useVideoConfig();
  const absoluteTimeMs = page.startMs + (frame / fps) * 1000;

  return (
    <AbsoluteFill style={{justifyContent: 'center', alignItems: 'center'}}>
      <div style={{fontSize: 80, fontWeight: 'bold', whiteSpace: 'pre'}}>
        {page.tokens.map((token) => {
          const isActive =
            token.fromMs <= absoluteTimeMs && token.toMs > absoluteTimeMs;

          return (
            <span
              key={token.fromMs}
              style={{color: isActive ? HIGHLIGHT_COLOR : 'white'}}
            >
              {token.text}
            </span>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};
```
