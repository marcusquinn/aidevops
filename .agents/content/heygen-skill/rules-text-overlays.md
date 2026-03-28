---
name: text-overlays
description: Adding text overlays with fonts and positioning to HeyGen videos
metadata:
  tags: text, overlays, fonts, positioning, graphics
---

# Text Overlays

Text overlays for titles, captions, lower thirds, and on-screen text in HeyGen videos.

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

Availability varies by API tier/plan.

## Positioning

**Coordinate system:** Origin top-left (0,0). X increases right, Y increases down. Units: pixels or percentage.

### Common Positions (1920×1080)

| Position | X | Y |
|----------|---|---|
| Top-left | 50 | 50 |
| Top-center | 960 | 50 |
| Top-right | 1870 | 50 |
| Center | 960 | 540 |
| Bottom-left | 50 | 1030 |
| Bottom-center | 960 | 1030 |
| Bottom-right | 1870 | 1030 |

### Position Helper

```typescript
interface Position { x: number; y: number; }

type Location = "top-left" | "top-center" | "top-right" | "center"
  | "bottom-left" | "bottom-center" | "bottom-right";

function getTextPosition(
  location: Location,
  videoWidth: number,
  videoHeight: number,
  padding: number = 50
): Position {
  const positions: Record<string, Position> = {
    "top-left": { x: padding, y: padding },
    "top-center": { x: videoWidth / 2, y: padding },
    "top-right": { x: videoWidth - padding, y: padding },
    "center": { x: videoWidth / 2, y: videoHeight / 2 },
    "bottom-left": { x: padding, y: videoHeight - padding },
    "bottom-center": { x: videoWidth / 2, y: videoHeight - padding },
    "bottom-right": { x: videoWidth - padding, y: videoHeight - padding },
  };
  return positions[location];
}
```

## Font Styling

| Font | Style | Use Case |
|------|-------|----------|
| Arial | Sans-serif | Clean, universal |
| Helvetica | Sans-serif | Modern, professional |
| Times New Roman | Serif | Traditional, formal |
| Georgia | Serif | Elegant, readable |
| Roboto | Sans-serif | Modern, digital |
| Open Sans | Sans-serif | Friendly, accessible |

## Templates

```typescript
interface TextOverlayTemplate {
  name: string;
  style: Partial<TextOverlay>;
}

const templates: TextOverlayTemplate[] = [
  {
    name: "title",
    style: {
      font_family: "Arial", font_size: 72,
      font_color: "#FFFFFF", text_align: "center",
    },
  },
  {
    name: "subtitle",
    style: {
      font_family: "Arial", font_size: 42,
      font_color: "#CCCCCC", text_align: "center",
    },
  },
  {
    name: "lower-third",
    style: {
      font_family: "Arial", font_size: 36,
      font_color: "#FFFFFF", background_color: "rgba(0, 0, 0, 0.7)",
      text_align: "left",
    },
  },
  {
    name: "caption",
    style: {
      font_family: "Arial", font_size: 32,
      font_color: "#FFFFFF", background_color: "rgba(0, 0, 0, 0.5)",
      text_align: "center",
    },
  },
];

function createTextOverlay(
  text: string,
  templateName: string,
  position: Position,
  duration?: { start: number; end: number }
): TextOverlay {
  const template = templates.find((t) => t.name === templateName);
  if (!template) throw new Error(`Template "${templateName}" not found`);
  return { text, x: position.x, y: position.y, ...template.style, duration };
}
```

### Usage Examples

```typescript
// Title card (centered, first 3 seconds)
createTextOverlay("Product Demo", "title", { x: 960, y: 540 }, { start: 0, end: 3 });

// Lower third with name/title
createTextOverlay("John Smith\nCEO, Company Inc.", "lower-third",
  { x: 100, y: 900 }, { start: 2, end: 8 });

// Call to action
createTextOverlay("Visit example.com", "subtitle",
  { x: 960, y: 1000 }, { start: 25, end: 30 });
```

## Timing Coordination

Coordinate text appearance with script timing:

```typescript
const script = `
Hello and welcome. [0:00 - 0:03]
Let me show you our features. [0:03 - 0:08]
First, we have analytics. [0:08 - 0:15]
Get started today! [0:15 - 0:20]
`;

const overlays = [
  { text: "Welcome", duration: { start: 0, end: 3 }, ...titleStyle },
  { text: "Feature Overview", duration: { start: 3, end: 8 }, ...subtitleStyle },
  { text: "Analytics Dashboard", duration: { start: 8, end: 15 }, ...lowerThirdStyle },
  { text: "www.example.com", duration: { start: 15, end: 20 }, ...ctaStyle },
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
