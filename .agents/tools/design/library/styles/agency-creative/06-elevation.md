# Design System: Agency Creative — Depth & Elevation

| Level | Name | Shadow Value (Dark) | Shadow Value (Light) | Usage |
|-------|------|--------------------|--------------------|-------|
| 0 | Flat | `none` | `none` | Default state, inline |
| 1 | Raised | `0 2px 8px rgba(0, 0, 0, 0.3)` | `0 2px 8px rgba(0, 0, 0, 0.06)` | Cards at rest |
| 2 | Elevated | `0 8px 32px rgba(0, 0, 0, 0.4)` | `0 8px 32px rgba(0, 0, 0, 0.1)` | Hover cards, dropdowns |
| 3 | Overlay | `0 16px 48px rgba(0, 0, 0, 0.5)` | `0 16px 48px rgba(0, 0, 0, 0.15)` | Modals, overlays |
| Glow | Primary | `0 8px 32px rgba(124, 58, 237, 0.3)` | `0 8px 32px rgba(124, 58, 237, 0.2)` | CTAs, primary emphasis |
| Glow | Accent | `0 8px 32px rgba(236, 72, 153, 0.25)` | `0 8px 32px rgba(236, 72, 153, 0.15)` | Accent emphasis |

**Elevation principles:**
- Colour shadows are a defining feature — use them on primary elements to extend the gradient palette into the space around the element
- Physical shadows (dark/neutral) are for structural elements; coloured glows are for interactive and hero elements
- Elevation changes should always animate (300ms ease) — never snap
- On dark backgrounds, shadows are less visible so pair them with subtle border or background shifts
