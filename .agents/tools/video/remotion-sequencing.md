---
name: sequencing
mode: subagent
description: Sequencing patterns for Remotion - delay, trim, limit duration of items
metadata:
  tags: sequence, series, timing, delay, trim
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Sequence

Delays when an element appears in the timeline. Wraps children in an absolute fill by default — use `layout="none"` to disable.

**Premounting:** Always set `premountFor={1 * fps}` on every `<Sequence>` — loads the component before playback starts.

**Local frames:** `useCurrentFrame()` inside a Sequence returns frames relative to sequence start (0-based), not the global frame.

```tsx
import {Sequence, useVideoConfig} from 'remotion';

const {fps} = useVideoConfig();

<Sequence from={1 * fps} durationInFrames={2 * fps} premountFor={1 * fps}>
  <Title />
</Sequence>
<Sequence from={2 * fps} durationInFrames={2 * fps} premountFor={1 * fps}>
  <Subtitle />
  {/* useCurrentFrame() returns 0-based frames, not global */}
</Sequence>
```

## Series

Sequential playback without overlap. Same absolute fill wrapping as `<Sequence>` — use `layout="none"` to disable. Negative `offset` starts the next sequence before the previous ends.

```tsx
import {Series} from 'remotion';

<Series>
  <Series.Sequence durationInFrames={45}>
    <Intro />
  </Series.Sequence>
  <Series.Sequence durationInFrames={60}>
    <MainContent />
  </Series.Sequence>
  <Series.Sequence offset={-15} durationInFrames={60}>
    {/* Starts 15 frames before MainContent ends */}
    <Outro />
  </Series.Sequence>
</Series>
```

## Nested Sequences

Nest `<Sequence>` for complex timing within a parent duration:

```tsx
<Sequence durationInFrames={120}>
  <Background />
  <Sequence from={15} durationInFrames={90} layout="none">
    <Title />
  </Sequence>
  <Sequence from={45} durationInFrames={60} layout="none">
    <Subtitle />
  </Sequence>
</Sequence>
```
