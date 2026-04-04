---
name: timing
mode: subagent
description: Interpolation curves in Remotion - linear, easing, spring animations
metadata:
  tags: spring, bounce, easing, interpolation
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Use `interpolate()` for direct frame-to-value mapping and `spring()` for physics-driven 0→1 progress.

## interpolate()

- `interpolate()` is unclamped by default.
- Clamp explicitly when values must stop at the range edges.

```ts title="Map opacity from frame 0-100"
import {interpolate} from 'remotion';

const opacity = interpolate(frame, [0, 100], [0, 1]);

const clamped = interpolate(frame, [0, 100], [0, 1], {
  extrapolateLeft: 'clamp',
  extrapolateRight: 'clamp',
});
```

## spring()

Springs produce natural motion from 0→1 over time.

```ts title="Basic spring"
import {spring, useCurrentFrame, useVideoConfig} from 'remotion';

const frame = useCurrentFrame();
const {fps} = useVideoConfig();

const scale = spring({frame, fps});
```

### Physics

- Default config: `mass: 1, damping: 10, stiffness: 100`.
- Default behaviour includes slight bounce.
- Recommended no-bounce preset: `{damping: 200}`.

```tsx
const smooth = {damping: 200}; // Smooth, no bounce; subtle reveals
const snappy = {damping: 20, stiffness: 200}; // Snappy; UI elements
const bouncy = {damping: 8}; // Playful entrance
const heavy = {damping: 15, stiffness: 80, mass: 2}; // Heavy, slow, small bounce
```

### Delay and duration

Use either a shifted frame or `delay`, and override the natural spring duration with `durationInFrames` when timing must be fixed.

```tsx
const entrance = spring({
  frame: frame - ENTRANCE_DELAY,
  fps,
  delay: 20,
});

const anim = spring({frame, fps, durationInFrames: 40});
```

### Reuse spring output

Spring output is just a number, so you can remap it with `interpolate()` or combine multiple springs arithmetically.

```tsx
const springProgress = spring({frame, fps});
const rotation = interpolate(springProgress, [0, 1], [0, 360]);

<div style={{rotate: rotation + 'deg'}} />;
```

```tsx
const {fps, durationInFrames} = useVideoConfig();

const inAnimation = spring({frame, fps});
const outAnimation = spring({
  frame,
  fps,
  durationInFrames: 1 * fps,
  delay: durationInFrames - 1 * fps,
});

const scale = inAnimation - outAnimation;
```

## Easing

- Pass `easing` to `interpolate()`.
- Default easing is `Easing.linear`.
- Convexities: `Easing.in`, `Easing.out`, `Easing.inOut`.
- Curves from most to least linear: `Easing.quad`, `Easing.sin`, `Easing.exp`, `Easing.circle`.
- `Easing.bezier(...)` is also supported.

```ts
import {interpolate, Easing} from 'remotion';

const value = interpolate(frame, [0, 100], [0, 1], {
  easing: Easing.inOut(Easing.quad),
  extrapolateLeft: 'clamp',
  extrapolateRight: 'clamp',
});
```

```ts
const value = interpolate(frame, [0, 100], [0, 1], {
  easing: Easing.bezier(0.8, 0.22, 0.96, 0.65),
  extrapolateLeft: 'clamp',
  extrapolateRight: 'clamp',
});
```
