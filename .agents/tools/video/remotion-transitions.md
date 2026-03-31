---
name: transitions
mode: subagent
description: Fullscreen scene transitions for Remotion.
metadata:
  tags: transitions, fade, slide, wipe, scenes
---

## Fullscreen transitions

Use `<TransitionSeries>` for fullscreen scene changes between clips or sequences; children are absolutely positioned and transitions overlap adjacent scenes.

## Install

Install `@remotion/transitions` before using these APIs:

```bash
npx remotion add @remotion/transitions # If project uses npm
bunx remotion add @remotion/transitions # If project uses bun
yarn remotion add @remotion/transitions # If project uses yarn
pnpm exec remotion add @remotion/transitions # If project uses pnpm
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

Import presentations from their module path:

```tsx
import {fade} from '@remotion/transitions/fade';
import {slide} from '@remotion/transitions/slide';
import {wipe} from '@remotion/transitions/wipe';
import {flip} from '@remotion/transitions/flip';
import {clockWipe} from '@remotion/transitions/clock-wipe';
```

## Directional slides

```tsx
import {slide} from '@remotion/transitions/slide';

<TransitionSeries.Transition presentation={slide({direction: 'from-left'})} timing={linearTiming({durationInFrames: 20})} />;
```

Directions: `"from-left"`, `"from-right"`, `"from-top"`, `"from-bottom"`.

## Timing Options

```tsx
import {linearTiming, springTiming} from '@remotion/transitions';

// Linear timing: constant speed
linearTiming({durationInFrames: 20});

// Spring timing: organic motion
springTiming({config: {damping: 200}, durationInFrames: 25});
```

Use `linearTiming()` for fixed durations and `springTiming()` for natural settling motion. If `springTiming()` omits `durationInFrames`, duration depends on `fps`.

## Duration math

Transitions overlap adjacent scenes, so total composition length is **shorter** than the sum of all sequence durations.

With two 60-frame sequences and a 15-frame transition:

- Without transitions: `60 + 60 = 120` frames
- With transition: `60 + 60 - 15 = 105` frames

Subtract each transition duration because both scenes play simultaneously during the overlap.

### Read a transition duration

Call `getDurationInFrames()` on the timing object:

```tsx
import {linearTiming, springTiming} from '@remotion/transitions';

const linearDuration = linearTiming({durationInFrames: 20}).getDurationInFrames({fps: 30});
// Returns 20

const springDuration = springTiming({config: {damping: 200}}).getDurationInFrames({fps: 30});
// Returns calculated duration based on spring physics
```

### Calculate total composition duration

```tsx
import {linearTiming} from '@remotion/transitions';

const scene1Duration = 60;
const scene2Duration = 60;
const scene3Duration = 60;

const timing1 = linearTiming({durationInFrames: 15});
const timing2 = linearTiming({durationInFrames: 20});

const transition1Duration = timing1.getDurationInFrames({fps: 30});
const transition2Duration = timing2.getDurationInFrames({fps: 30});

const totalDuration = scene1Duration + scene2Duration + scene3Duration - transition1Duration - transition2Duration;
// 60 + 60 + 60 - 15 - 20 = 145 frames
```
