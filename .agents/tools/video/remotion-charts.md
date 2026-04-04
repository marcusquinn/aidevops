---
name: charts
mode: subagent
description: Chart and data visualization patterns for Remotion. Use when creating bar charts, pie charts, histograms, progress bars, or any data-driven animations.
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Charts in Remotion

Use regular React, HTML, SVG, or D3. Disable third-party animation systems — they flicker during render. Drive all chart motion from `useCurrentFrame()`.

## Bar charts — staggered bars

Animate each bar height with a per-bar delay:

```tsx
const STAGGER_DELAY = 5;
const frame = useCurrentFrame();
const {fps} = useVideoConfig();

const bars = data.map((item, i) => {
  const delay = i * STAGGER_DELAY;
  const height = spring({
    frame,
    fps,
    delay,
    config: {damping: 200},
  });
  return <div style={{height: height * item.value}} />;
});
```

## Pie charts

Animate segments with `strokeDashoffset` and rotate the circle so drawing starts at 12 o'clock.

```tsx
const frame = useCurrentFrame();
const {fps} = useVideoConfig();

const progress = interpolate(frame, [0, 100], [0, 1]);

const circumference = 2 * Math.PI * radius;
const segmentLength = (value / total) * circumference;
const offset = interpolate(progress, [0, 1], [segmentLength, 0]);

<circle r={radius} cx={center} cy={center} fill="none" stroke={color} strokeWidth={strokeWidth} strokeDasharray={`${segmentLength} ${circumference}`} strokeDashoffset={offset} transform={`rotate(-90 ${center} ${center})`} />;
```
