# Design System: Startup Minimal — Depth & Elevation

| Level | Name | Shadow Value | Usage |
|-------|------|-------------|-------|
| 0 | Flat | `none` | Default — most elements live here |
| 1 | Resting | `0 1px 2px rgba(0, 0, 0, 0.04)` | Inputs at rest, subtle grounding |
| 2 | Raised | `0 2px 8px rgba(0, 0, 0, 0.06)` | Dropdowns, interactive card hover |
| 3 | Overlay | `0 4px 16px rgba(0, 0, 0, 0.08)` | Modals, command palette, popovers |
| Focus | Ring | `0 0 0 3px rgba(37, 99, 235, 0.1)` | Focus state ring on inputs and buttons |

**Elevation principles:**
- Most elements are flat (level 0). Borders, not shadows, create structure.
- Shadow is reserved for elements that float above the page (dropdowns, modals, popovers)
- The system uses only 3 shadow levels total — complexity here is a code smell
- Focus rings use box-shadow for a clean, padded focus indicator
- Never combine border and shadow for structure on the same element — choose one
