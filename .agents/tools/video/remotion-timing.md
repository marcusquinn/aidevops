---
name: timing
mode: subagent
description: Interpolation curves in Remotion - linear, easing, spring animations
metadata:
  tags: spring, bounce, easing, interpolation
---

Linear interpolation uses the `interpolate` function. Values are unclamped by default:

```ts title="Going from 0 to 1 over 100 frames"
import {interpolate} from 'remotion';

const opacity = interpolate(frame, [0, 100], [0, 1]);

// With clamping:
const clamped = interpolate(frame, [0, 100], [0, 1], {
  extrapolateLeft: 'clamp',
  extrapolateRight: 'clamp',
});
```

## Spring animations

Springs produce natural motion from 0 to 1 over time.

```ts title="Spring animation"
import {spring, useCurrentFrame, useVideoConfig} from 'remotion';

const frame = useCurrentFrame();
const {fps} = useVideoConfig();

const scale = spring({frame, fps});
```

### Physical properties

Default: `mass: 1, damping: 10, stiffness: 100` — produces slight bounce. Recommended no-bounce config: `{ damping: 200 }`.

Common presets:

```tsx
const smooth = {damping: 200}; // Smooth, no bounce (subtle reveals)
const snappy = {damping: 20, stiffness: 200}; // Snappy, minimal bounce (UI elements)
const bouncy = {damping: 8}; // Bouncy entrance (playful animations)
const heavy = {damping: 15, stiffness: 80, mass: 2}; // Heavy, slow, small bounce
```

### Delay

```tsx
const entrance = spring({
  frame: frame - ENTRANCE_DELAY,
  fps,
  delay: 20,
});
```

### Duration

Springs have a natural duration from their physical properties. Override with `durationInFrames`:

```tsx
const anim = spring({frame, fps, durationInFrames: 40});
```

### Combining spring() with interpolate()

Map spring output (0–1) to any range:

```tsx
const springProgress = spring({frame, fps});
const rotation = interpolate(springProgress, [0, 1], [0, 360]);

<div style={{rotate: rotation + 'deg'}} />;
```

### Adding springs

Springs are numbers — arithmetic works directly:

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

Pass an `easing` option to `interpolate`. Default is `Easing.linear`.

Convexities: `Easing.in` (slow start), `Easing.out` (slow end), `Easing.inOut`.
Curves (most to least linear): `Easing.quad`, `Easing.sin`, `Easing.exp`, `Easing.circle`.

Combine convexity + curve:

```ts
import {interpolate, Easing} from 'remotion';

const value = interpolate(frame, [0, 100], [0, 1], {
  easing: Easing.inOut(Easing.quad),
  extrapolateLeft: 'clamp',
  extrapolateRight: 'clamp',
});
```

Cubic bezier curves are also supported:

```ts
const value = interpolate(frame, [0, 100], [0, 1], {
  easing: Easing.bezier(0.8, 0.22, 0.96, 0.65),
  extrapolateLeft: 'clamp',
  extrapolateRight: 'clamp',
});
```
