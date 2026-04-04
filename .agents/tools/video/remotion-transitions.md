---
name: transitions
mode: subagent
description: Fullscreen scene transitions for Remotion.
metadata:
  tags: transitions, fade, slide, wipe, scenes
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Fullscreen transitions

Use `<TransitionSeries>` for fullscreen scene changes; children are absolutely positioned and transitions overlap adjacent scenes.

## Install

```bash
npx remotion add @remotion/transitions  # npm
bunx remotion add @remotion/transitions  # bun
yarn remotion add @remotion/transitions  # yarn
pnpm exec remotion add @remotion/transitions  # pnpm
```

## Core pattern

```tsx
import {TransitionSeries, linearTiming} from '@remotion/transitions';
import {fade} from '@remotion/transitions/fade';

<TransitionSeries>
  <TransitionSeries.Sequence durationInFrames={60}>
    <SceneA />
  </TransitionSeries.Sequence>
  <TransitionSeries.Transition presentation={fade()} timing={linearTiming({durationInFrames: 15})} />
  <TransitionSeries.Sequence durationInFrames={60}>
    <SceneB />
  </TransitionSeries.Sequence>
</TransitionSeries>;
```

## Built-in presentations

| Presentation | Import path |
|---|---|
| `fade()` | `@remotion/transitions/fade` |
| `slide()` | `@remotion/transitions/slide` |
| `wipe()` | `@remotion/transitions/wipe` |
| `flip()` | `@remotion/transitions/flip` |
| `clockWipe()` | `@remotion/transitions/clock-wipe` |

`slide()` accepts `direction`: `"from-left"` | `"from-right"` | `"from-top"` | `"from-bottom"`.

## Timing

```tsx
import {linearTiming, springTiming} from '@remotion/transitions';

linearTiming({durationInFrames: 20});                              // constant speed
springTiming({config: {damping: 200}, durationInFrames: 25});     // organic motion
```

Use `linearTiming()` for fixed durations; `springTiming()` for natural settling. Omitting `durationInFrames` from `springTiming()` makes duration fps-dependent.

## Duration math

Transitions overlap adjacent scenes — total length is **shorter** than the sum of sequence durations:

```ts
// total = sum(sequenceDurations) - sum(transitionDurations)
// e.g. 60 + 60 - 15 = 105 frames
```

Read a transition's duration: `timing.getDurationInFrames({fps: 30})`.
