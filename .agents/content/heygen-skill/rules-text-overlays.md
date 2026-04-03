---
name: text-overlays
description: Adding text overlays with fonts and positioning to HeyGen videos
metadata:
  tags: text, overlays, fonts, positioning, graphics
---

# Text Overlays

## Text Overlay Interface

```typescript
interface TextOverlay {
  text: string;
  x: number;          // X position (pixels or percentage)
  y: number;          // Y position (pixels or percentage)
  width?: number;
  height?: number;
  font_family?: string;
  font_size?: number;
  font_color?: string;
  font_weight?: string;
  background_color?: string;
  text_align?: "left" | "center" | "right";
  duration?: {
    start: number;    // Start time in seconds
    end: number;      // End time in seconds
  };
}
```

## Positioning

Origin top-left (0,0). X increases right, Y increases down. Units: pixels or percentage.

**Common positions (1920×1080):**

| Position | X | Y |
|----------|---|---|
| Top-left | 50 | 50 |
| Top-center | 960 | 50 |
| Top-right | 1870 | 50 |
| Center | 960 | 540 |
| Bottom-left | 50 | 1030 |
| Bottom-center | 960 | 1030 |
| Bottom-right | 1870 | 1030 |

## Font Styling

| Font | Style | Use Case |
|------|-------|----------|
| Arial | Sans-serif | Clean, universal |
| Helvetica | Sans-serif | Modern, professional |
| Times New Roman | Serif | Traditional, formal |
| Georgia | Serif | Elegant, readable |
| Roboto | Sans-serif | Modern, digital |
| Open Sans | Sans-serif | Friendly, accessible |

## Named Style Presets

| Name | font_size | font_color | background_color | text_align |
|------|-----------|------------|------------------|------------|
| title | 72 | #FFFFFF | — | center |
| subtitle | 42 | #CCCCCC | — | center |
| lower-third | 36 | #FFFFFF | rgba(0,0,0,0.7) | left |
| caption | 32 | #FFFFFF | rgba(0,0,0,0.5) | center |

All presets use `font_family: "Arial"`.

## Timing Coordination

```typescript
const overlays = [
  { text: "Welcome",            duration: { start: 0,  end: 3  }, ...titleStyle },
  { text: "Feature Overview",   duration: { start: 3,  end: 8  }, ...subtitleStyle },
  { text: "Analytics Dashboard",duration: { start: 8,  end: 15 }, ...lowerThirdStyle },
  { text: "www.example.com",    duration: { start: 15, end: 20 }, ...subtitleStyle },
];
```

## Best Practices

1. **Contrast** — sufficient contrast between text and background
2. **Size** — large enough to read on mobile
3. **Duration** — minimum 3 seconds reading time
4. **Positioning** — don't overlap the avatar's face
5. **Consistency** — consistent fonts and styles throughout
6. **Accessibility** — color-blind friendly palettes

## Limitations

- Text overlay support varies by subscription tier
- Some advanced styling options may not be available via API
- Complex animations may require post-production tools
- For auto-generated captions, see [captions.md](captions.md)
