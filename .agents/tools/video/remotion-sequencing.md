---
name: sequencing
mode: subagent
description: Sequencing patterns for Remotion - delay, trim, limit duration of items
metadata:
  tags: sequence, series, timing, delay, trim
---

## Sequence

Delays when an element appears in the timeline. Wraps children in an absolute fill element by default — use `layout="none"` to disable.

```tsx
import {Sequence, useVideoConfig} from 'remotion';

const {fps} = useVideoConfig();

<Sequence from={1 * fps} durationInFrames={2 * fps} premountFor={1 * fps}>
  <Title />
</Sequence>
<Sequence from={2 * fps} durationInFrames={2 * fps} premountFor={1 * fps}>
  <Subtitle />
</Sequence>
```

**Premounting:** Always set `premountFor={1 * fps}` on every `<Sequence>` — loads the component before playback starts.

**Local frames:** Inside a Sequence, `useCurrentFrame()` returns frame relative to sequence start (0-based), not the global frame.

```tsx
<Sequence from={60} durationInFrames={30}>
  <MyComponent />
  {/* useCurrentFrame() returns 0-29, not 60-89 */}
</Sequence>
```

## Series

Sequential playback without overlap. Same absolute fill wrapping as `<Sequence>` — use `layout="none"` to disable.

```tsx
import {Series} from 'remotion';

<Series>
  <Series.Sequence durationInFrames={45}>
    <Intro />
  </Series.Sequence>
  <Series.Sequence durationInFrames={60}>
    <MainContent />
  </Series.Sequence>
  <Series.Sequence durationInFrames={30}>
    <Outro />
  </Series.Sequence>
</Series>;
```

### Overlaps

Negative `offset` starts the next sequence before the previous ends:

```tsx
<Series>
  <Series.Sequence durationInFrames={60}>
    <SceneA />
  </Series.Sequence>
  <Series.Sequence offset={-15} durationInFrames={60}>
    {/* Starts 15 frames before SceneA ends */}
    <SceneB />
  </Series.Sequence>
</Series>
```

## Nested Sequences

Sequences nest for complex timing:

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
