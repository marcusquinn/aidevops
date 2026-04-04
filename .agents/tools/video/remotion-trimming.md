---
name: trimming
mode: subagent
description: Trimming patterns for Remotion - cut the beginning or end of animations
metadata:
  tags: sequence, trim, clip, cut, offset
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Trim the beginning

A negative `from` value skips that many frames from the start of the animation's local timeline:

```tsx
import {Sequence, useVideoConfig} from 'remotion';

const {fps} = useVideoConfig();

<Sequence from={-0.5 * fps}>
  <MyAnimation />
</Sequence>
```

Inside `<MyAnimation>`, `useCurrentFrame()` starts at `0.5 * fps` instead of 0.

## Trim the end

Use `durationInFrames` to unmount content after a fixed duration:

```tsx
<Sequence durationInFrames={1.5 * fps}>
  <MyAnimation />
</Sequence>
```

## Trim and delay

Nest sequences to trim the beginning and delay when the result appears:

```tsx
<Sequence from={30}>
  <Sequence from={-15}>
    <MyAnimation />
  </Sequence>
</Sequence>
```

The inner sequence trims 15 frames from the start; the outer delays the result by 30 frames.
