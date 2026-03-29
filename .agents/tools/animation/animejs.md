---
name: animejs
description: "Anime.js - Lightweight JavaScript animation library for CSS, SVG, DOM attributes and JS objects"
mode: subagent
upstream_url: https://github.com/juliangarnier/anime
docs_url: https://animejs.com/documentation
---
# Anime.js

## Quick Reference

```javascript
import { animate, createTimeline, stagger, utils, svg } from 'animejs';

animate('.element', { translateX: 250, opacity: 0.5, duration: 800, ease: 'outExpo' });

const tl = createTimeline({ defaults: { duration: 500 } });
tl.add('.box1', { translateX: 100 }).add('.box2', { translateY: 100 }, '-=200');

animate('.items', { scale: [0, 1], delay: stagger(100, { from: 'center' }) });
```

## Installation

```bash
npm install animejs
# or CDN: <script src="https://cdn.jsdelivr.net/npm/animejs@4/lib/anime.min.js"></script>
```

## Targets

| Type | Example |
|------|---------|
| CSS Selector | `'.my-class'`, `'#my-id'` |
| DOM Element | `document.querySelector('.el')` |
| NodeList | `document.querySelectorAll('.els')` |
| JS Object | `{ x: 0, y: 0 }` |
| Array | `[element1, element2]` |

## Animation Parameters

```javascript
animate('.element', {
  // Properties
  translateX: 100, translateY: 50, rotate: '45deg', scale: 1.5, skewX: '10deg',
  opacity: 0.5, backgroundColor: '#ff0000', fontSize: '24px',
  '--custom-prop': 100,

  // Timing
  duration: 1000, delay: 500, endDelay: 200,

  // Easing — see Easing section for full options
  ease: 'outExpo',

  // Playback
  loop: true, alternate: true, reversed: true, autoplay: false,
  playbackRate: 1.5, frameRate: 60
});
```

## Easing

Standard: `in/out/inOut` + `Quad`, `Cubic`, `Quart`, `Quint`, `Sine`, `Expo`, `Circ`, `Back`, `Elastic`, `Bounce`

```javascript
ease: 'out(3)'                        // power shorthand
ease: 'spring(mass, stiffness, damping, velocity)'
ease: 'cubicBezier(0.5, 0, 0.5, 1)'
```

## Keyframes

```javascript
// Array syntax
animate('.element', {
  translateX: [0, 100, 50, 200],
  opacity: [{ to: 0, duration: 500 }, { to: 1, duration: 500 }]
});

// Object syntax
animate('.element', {
  translateX: { from: 0, to: 250, duration: 1000, ease: 'outExpo' },
  rotate: { from: '-1turn', to: 0, delay: 200 }
});
```

## Timeline

```javascript
const tl = createTimeline({ defaults: { duration: 500, ease: 'outExpo' }, loop: 2 });

tl.add('.el1', { x: 100 })             // after previous
  .add('.el2', { x: 100 }, '+=200')    // 200ms after previous ends
  .add('.el3', { x: 100 }, '-=100')    // 100ms before previous ends
  .add('.el4', { x: 100 }, 500)        // absolute 500ms
  .add('.el5', { x: 100 }, 'myLabel'); // at label

tl.label('intro').add('.title', { opacity: 1 }).label('content').add('.body', { translateY: 0 });
tl.seek('content');
```

| Method / Property | Description |
|-------------------|-------------|
| `play()` / `pause()` | Start / pause |
| `restart()` / `reverse()` | Restart / reverse direction |
| `seek(time)` | Jump to time in ms (`anim.progress = 0.5` for %) |
| `complete()` / `cancel()` | Jump to end / stop and reset |
| `revert()` | Restore initial state |
| `progress` / `currentTime` | 0–100 / ms elapsed |
| `paused` / `completed` | Boolean state |

```javascript
const anim = animate('.element', { translateX: 250, autoplay: false });
anim.play(); anim.pause(); anim.seek(anim.duration * 0.5);
```

## Stagger

```javascript
animate('.items', { translateY: [50, 0], delay: stagger(100) });

stagger(value, {
  start: 500, from: 'center',   // 'first', 'last', 'center', index
  direction: 'reverse', ease: 'outQuad',
  grid: [10, 10], axis: 'x'    // grid stagger
});

// Value stagger: translateX: stagger(10) → 0, 10, 20...
animate('.items', { rotate: stagger([0, 360], { ease: 'outQuad' }) });
```

## SVG

```javascript
// Line drawing
const drawable = svg.createDrawable('.path');
animate(drawable, { draw: ['0 0', '0 1', '1 1'], duration: 2000, ease: 'inOutQuad' });

// Morphing
animate('.shape', { d: [{ to: 'M10 80 Q 95 10 180 80' }, { to: 'M10 80 Q 95 150 180 80' }], loop: true, alternate: true });

// Motion path
const path = svg.createMotionPath('.motion-path');
animate('.element', { ...path(), duration: 2000, ease: 'linear' });
```

## Callbacks & Promises

```javascript
animate('.element', {
  onBegin: (anim) => {},
  onUpdate: (anim) => {},     // anim.progress (0–100)
  onComplete: (anim) => {},
  onLoop: (anim) => {},       // also: onPause, onRender, onBeforeUpdate
});

await animate('.box1', { translateX: 100 });  // promises supported
```

## Utilities

```javascript
utils.$('.selector');              // DOM selection (import { utils } from 'animejs')
utils.random(0, 100);              // float; pass true for integer
utils.clamp(value, 0, 100);
utils.mapRange(value, 0, 1, 0, 100);
utils.round(3.14159, 2);           // 3.14
```

## Migration v3 → v4

| v3 | v4 |
|----|----|
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
