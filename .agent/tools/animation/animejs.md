---
description: "Anime.js - Lightweight JavaScript animation library for CSS, SVG, DOM attributes and JS objects"
mode: subagent
imported_from: context7
upstream_url: https://github.com/juliangarnier/anime
docs_url: https://animejs.com/documentation
context7_id: /websites/animejs
---
# Anime.js

Anime.js is a lightweight JavaScript animation library with a simple yet powerful API. It works with CSS properties, SVG, DOM attributes, and JavaScript Objects.

## Quick Reference

```javascript
import { animate, createTimeline, stagger, utils, svg } from 'animejs';

// Basic animation
animate('.element', {
  translateX: 250,
  opacity: 0.5,
  duration: 800,
  ease: 'outExpo'
});

// Timeline
const tl = createTimeline({ defaults: { duration: 500 } });
tl.add('.box1', { translateX: 100 })
  .add('.box2', { translateY: 100 }, '-=200');

// Stagger
animate('.items', {
  scale: [0, 1],
  delay: stagger(100, { from: 'center' })
});
```

## Installation

```bash
npm install animejs
```

```html
<script src="https://cdn.jsdelivr.net/npm/animejs@4/lib/anime.min.js"></script>
```

## Core Concepts

### Targets

Anime.js can animate:

| Target Type | Example |
|-------------|---------|
| CSS Selector | `'.my-class'`, `'#my-id'` |
| DOM Element | `document.querySelector('.el')` |
| NodeList | `document.querySelectorAll('.els')` |
| JavaScript Object | `{ x: 0, y: 0 }` |
| Array | `[element1, element2]` |

### Animatable Properties

```javascript
animate('.square', {
  // CSS Properties
  opacity: 0.5,
  backgroundColor: '#ff0000',
  fontSize: '24px',
  
  // CSS Transforms
  translateX: 100,
  translateY: 50,
  rotate: '45deg',
  scale: 1.5,
  skewX: '10deg',
  
  // CSS Variables
  '--custom-prop': 100,
  
  // SVG Attributes
  strokeDashoffset: [anime.setDashoffset, 0],
  points: '64 128 8.574 96 8.574 32 64 0 119.426 32 119.426 96'
});
```

### Animation Parameters

```javascript
animate('.element', {
  translateX: 250,
  
  // Timing
  duration: 1000,        // ms
  delay: 500,            // ms
  endDelay: 200,         // ms after animation
  
  // Easing
  ease: 'outExpo',       // Built-in easing
  ease: 'spring(1, 80, 10, 0)', // Spring physics
  
  // Playback
  loop: true,            // or number
  alternate: true,       // Ping-pong
  reversed: true,        // Play backwards
  autoplay: false,       // Manual control
  
  // Speed
  playbackRate: 1.5,     // 1.5x speed
  frameRate: 60          // FPS cap
});
```

## Easing Functions

### Built-in Easings

| Category | Functions |
|----------|-----------|
| Linear | `linear` |
| Quad | `inQuad`, `outQuad`, `inOutQuad` |
| Cubic | `inCubic`, `outCubic`, `inOutCubic` |
| Quart | `inQuart`, `outQuart`, `inOutQuart` |
| Quint | `inQuint`, `outQuint`, `inOutQuint` |
| Sine | `inSine`, `outSine`, `inOutSine` |
| Expo | `inExpo`, `outExpo`, `inOutExpo` |
| Circ | `inCirc`, `outCirc`, `inOutCirc` |
| Back | `inBack`, `outBack`, `inOutBack` |
| Elastic | `inElastic`, `outElastic`, `inOutElastic` |
| Bounce | `inBounce`, `outBounce`, `inOutBounce` |

### Parametric Easings

```javascript
// Shorthand with power
ease: 'out(3)'           // outQuad equivalent
ease: 'inOut(4)'         // inOutQuart equivalent

// Spring physics
ease: 'spring(mass, stiffness, damping, velocity)'
ease: 'spring(1, 80, 10, 0)'

// Custom cubic bezier
ease: 'cubicBezier(0.5, 0, 0.5, 1)'
```

## Keyframes

### Array Syntax

```javascript
animate('.element', {
  translateX: [0, 100, 50, 200],  // Sequential keyframes
  opacity: [
    { to: 0, duration: 500 },
    { to: 1, duration: 500 }
  ]
});
```

### Object Syntax

```javascript
animate('.element', {
  translateX: {
    from: 0,
    to: 250,
    duration: 1000,
    ease: 'outExpo'
  },
  rotate: {
    from: '-1turn',
    to: 0,
    delay: 200
  }
});
```

## Timeline

### Creating Timelines

```javascript
const tl = createTimeline({
  defaults: {
    duration: 500,
    ease: 'outExpo'
  },
  autoplay: false,
  loop: 2
});

// Add animations sequentially
tl.add('.box1', { translateX: 100 })
  .add('.box2', { translateY: 100 })
  .add('.box3', { scale: 2 });
```

### Time Positioning

```javascript
tl.add('.el1', { x: 100 })                    // After previous
  .add('.el2', { x: 100 }, '+=200')           // 200ms after previous
  .add('.el3', { x: 100 }, '-=100')           // 100ms before previous ends
  .add('.el4', { x: 100 }, 500)               // At absolute 500ms
  .add('.el5', { x: 100 }, 'myLabel')         // At label position
  .add('.el6', { x: 100 }, 'myLabel+=100');   // 100ms after label
```

### Labels

```javascript
tl.label('intro')
  .add('.title', { opacity: 1 })
  .label('content')
  .add('.body', { translateY: 0 });

// Jump to label
tl.seek('content');
```

### Timeline Methods

| Method | Description |
|--------|-------------|
| `play()` | Start playback |
| `pause()` | Pause playback |
| `restart()` | Restart from beginning |
| `reverse()` | Reverse direction |
| `seek(time)` | Jump to time (ms or progress 0-1) |
| `complete()` | Jump to end |
| `cancel()` | Stop and reset |
| `revert()` | Restore initial state |

## Stagger

### Basic Stagger

```javascript
animate('.items', {
  translateY: [50, 0],
  opacity: [0, 1],
  delay: stagger(100)  // 100ms between each
});
```

### Stagger Parameters

```javascript
stagger(value, {
  start: 500,           // Initial delay
  from: 'center',       // 'first', 'last', 'center', index
  direction: 'reverse', // Reverse order
  ease: 'outQuad',      // Easing for stagger progression
  grid: [10, 10],       // Grid dimensions
  axis: 'x'             // 'x', 'y' for grid
});
```

### Grid Stagger

```javascript
animate('.grid-item', {
  scale: [0, 1],
  delay: stagger(50, {
    grid: [10, 10],
    from: 'center',
    axis: 'y'
  })
});
```

### Value Stagger

```javascript
animate('.items', {
  translateX: stagger(10),           // 0, 10, 20, 30...
  translateX: stagger([0, 100]),     // Distributed 0-100
  rotate: stagger([0, 360], { ease: 'outQuad' })
});
```

## SVG Animations

### Line Drawing

```javascript
import { animate, svg } from 'animejs';

// Create drawable from SVG path
const drawable = svg.createDrawable('.path');

animate(drawable, {
  draw: ['0 0', '0 1', '1 1'],  // from, via, to
  duration: 2000,
  ease: 'inOutQuad'
});
```

### Morphing

```javascript
animate('.shape', {
  d: [
    { to: 'M10 80 Q 95 10 180 80' },
    { to: 'M10 80 Q 95 150 180 80' }
  ],
  duration: 1000,
  loop: true,
  alternate: true
});
```

### Motion Path

```javascript
import { svg } from 'animejs';

const path = svg.createMotionPath('.motion-path');

animate('.element', {
  ...path(),  // Spread motion path properties
  duration: 2000,
  ease: 'linear'
});
```

## Callbacks

```javascript
animate('.element', {
  translateX: 250,
  
  onBegin: (anim) => {
    console.log('Animation started');
  },
  
  onUpdate: (anim) => {
    console.log(`Progress: ${anim.progress}%`);
  },
  
  onLoop: (anim) => {
    console.log(`Loop ${anim.currentLoop}`);
  },
  
  onComplete: (anim) => {
    console.log('Animation finished');
  },
  
  onPause: (anim) => {},
  onRender: (anim) => {},
  onBeforeUpdate: (anim) => {}
});
```

## Promises

```javascript
// Async/await
async function animateSequence() {
  await animate('.box1', { translateX: 100 });
  await animate('.box2', { translateY: 100 });
  console.log('All done!');
}

// Promise chaining
animate('.element', { opacity: 0 })
  .then(() => animate('.element', { display: 'none' }));
```

## Utilities

```javascript
import { utils } from 'animejs';

// DOM selection
const elements = utils.$('.selector');

// Random values
const rand = utils.random(0, 100);
const randInt = utils.random(0, 100, true);  // Integer

// Clamping
const clamped = utils.clamp(value, 0, 100);

// Mapping
const mapped = utils.mapRange(value, 0, 1, 0, 100);

// Rounding
const rounded = utils.round(3.14159, 2);  // 3.14
```

## Playback Control

```javascript
const anim = animate('.element', {
  translateX: 250,
  autoplay: false
});

// Control methods
anim.play();
anim.pause();
anim.restart();
anim.reverse();
anim.seek(500);        // Time in ms
anim.seek(0.5);        // Progress (0-1)

// Properties
anim.progress;         // Current progress (0-100)
anim.currentTime;      // Current time in ms
anim.paused;           // Boolean
anim.completed;        // Boolean
```

## Common Patterns

### Fade In

```javascript
animate('.element', {
  opacity: [0, 1],
  translateY: [20, 0],
  duration: 600,
  ease: 'outExpo'
});
```

### Staggered List

```javascript
animate('.list-item', {
  opacity: [0, 1],
  translateX: [-20, 0],
  delay: stagger(50),
  ease: 'outExpo'
});
```

### Pulse Effect

```javascript
animate('.button', {
  scale: [1, 1.1, 1],
  duration: 300,
  ease: 'inOutQuad'
});
```

### Infinite Rotation

```javascript
animate('.spinner', {
  rotate: '1turn',
  duration: 1000,
  ease: 'linear',
  loop: true
});
```

### Scroll-triggered

```javascript
const observer = new IntersectionObserver((entries) => {
  entries.forEach(entry => {
    if (entry.isIntersecting) {
      animate(entry.target, {
        opacity: [0, 1],
        translateY: [50, 0]
      });
    }
  });
});

document.querySelectorAll('.animate-on-scroll').forEach(el => {
  observer.observe(el);
});
```

## Migration from v3 to v4

| v3 | v4 |
|----|-----|
| `anime({...})` | `animate(targets, {...})` |
| `anime.timeline()` | `createTimeline()` |
| `anime.stagger()` | `stagger()` |
| `easing: 'easeOutExpo'` | `ease: 'outExpo'` |
| `direction: 'alternate'` | `alternate: true` |
| `anime.remove()` | `anim.revert()` |

## Resources

- [Official Documentation](https://animejs.com/documentation)
- [GitHub Repository](https://github.com/juliangarnier/anime)
- [CodePen Examples](https://codepen.io/collection/XLebem)
