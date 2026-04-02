---
name: trimming
mode: subagent
description: Trimming patterns for Remotion - cut the beginning or end of animations
metadata:
  tags: sequence, trim, clip, cut, offset
---

## Trim the beginning

A negative `from` value shifts time backwards — the sequence starts partway through its local timeline:

```tsx
import {Sequence, useVideoConfig} from 'remotion';

const {fps} = useVideoConfig();

<Sequence from={-0.5 * fps}>
  <MyAnimation />
</Sequence>
```

- The animation appears 15 frames into its progress, so the first 15 frames are skipped.
- Inside `<MyAnimation>`, `useCurrentFrame()` starts at 15 instead of 0.

## Trim the end

Use `durationInFrames` to unmount content after a fixed duration:

```tsx
<Sequence durationInFrames={1.5 * fps}>
  <MyAnimation />
</Sequence>
```

- The animation plays for 45 frames, then the component unmounts.

## Trim and delay

Nest sequences to trim the beginning and delay when the result appears:

```tsx
<Sequence from={30}>
  <Sequence from={-15}>
    <MyAnimation />
  </Sequence>
</Sequence>
```

- The inner sequence trims 15 frames from the start.
- The outer sequence delays the trimmed result by 30 frames.
