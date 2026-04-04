# Design System: Corporate Modern — Depth & Elevation

## Shadow Scale

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Default cards (use border instead) |
| 1 | Raised | `0 1px 3px rgba(26, 26, 46, 0.04), 0 1px 2px rgba(26, 26, 46, 0.03)` | Subtle card lift |
| 2 | Elevated | `0 4px 12px rgba(26, 26, 46, 0.06), 0 2px 4px rgba(26, 26, 46, 0.03)` | Hover cards, floating toolbar |
| 3 | Overlay | `0 8px 24px rgba(26, 26, 46, 0.08), 0 4px 8px rgba(26, 26, 46, 0.04)` | Dropdowns, popovers |
| 4 | Modal | `0 16px 48px rgba(26, 26, 46, 0.12), 0 8px 16px rgba(26, 26, 46, 0.06)` | Modals, command palettes |

## Elevation Principles

- Default cards use border, not shadow — shadow appears on hover
- Shadows use the charcoal base colour for tint consistency
- Never combine border and heavy shadow on the same element
- Modal backdrop: `rgba(26, 26, 46, 0.4)` with `backdrop-filter: blur(4px)`
