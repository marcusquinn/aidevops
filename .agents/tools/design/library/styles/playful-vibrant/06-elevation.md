# Design System: Playful Vibrant — Depth & Elevation

## Shadow Scale

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Inline elements, badges |
| 1 | Soft | `0 2px 8px rgba(0, 0, 0, 0.04), 0 1px 3px rgba(0, 0, 0, 0.03)` | Cards at rest, nav bar |
| 2 | Raised | `0 4px 16px rgba(0, 0, 0, 0.06), 0 2px 6px rgba(0, 0, 0, 0.04)` | Hover cards, active dropdowns |
| 3 | Elevated | `0 12px 32px rgba(0, 0, 0, 0.1), 0 4px 12px rgba(0, 0, 0, 0.05)` | Popovers, floating menus |
| 4 | Overlay | `0 24px 48px rgba(0, 0, 0, 0.14), 0 8px 24px rgba(0, 0, 0, 0.06)` | Modals, full overlays |

## Coloured Shadows

For primary buttons and feature cards:

| Element | Shadow |
|---------|--------|
| Primary button | `0 4px 14px rgba(99, 102, 241, 0.35)` |
| Accent button | `0 4px 14px rgba(244, 63, 94, 0.35)` |
| Feature card hover | `0 12px 32px rgba(99, 102, 241, 0.12)` |

## Elevation Principles

- Coloured shadows match the element's primary colour — never neutral-only
- Cards always have at least a soft shadow (level 1) — no flat cards with borders
- Hover states increase shadow AND add slight `translateY` for physical feel
- Spring easing on hover: `cubic-bezier(0.34, 1.56, 0.64, 1)`
- Modal backdrop: `rgba(30, 27, 75, 0.3)` — slightly indigo-tinted
