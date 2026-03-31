---
name: charts
mode: subagent
description: Chart and data visualization patterns for Remotion. Use when creating bar charts, pie charts, histograms, progress bars, or any data-driven animations.
metadata:
  tags: charts, data, visualization, bar-chart, pie-chart, graphs
---

# Charts in Remotion

Use regular React, HTML, SVG, or D3 to build charts in Remotion.

## Animation rule

Disable third-party animation systems. They flicker during render. Drive chart motion from `useCurrentFrame()` instead.

## Bar charts

See [Bar Chart Example](assets/charts/bar-chart.tsx) for a basic implementation.

### Staggered bars

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
