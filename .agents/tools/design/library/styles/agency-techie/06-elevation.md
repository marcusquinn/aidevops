<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agency Techie — Depth & Elevation

| Level | Name | Shadow Value | Usage |
|-------|------|-------------|-------|
| 0 | Flat | `none` | Default state, inline elements |
| 1 | Raised | `0 1px 3px rgba(0, 0, 0, 0.4)` | Cards at rest, nav bar |
| 2 | Elevated | `0 4px 12px rgba(0, 0, 0, 0.5)` | Dropdowns, hover cards |
| 3 | Overlay | `0 8px 24px rgba(0, 0, 0, 0.6), 0 0 0 1px rgba(255,255,255,0.05)` | Modals, command palettes, tooltips |
| Glow | Focus | `0 0 0 3px rgba(34, 211, 238, 0.15)` | Focus rings on interactive elements |

**Elevation principles:**
- Dark mode relies on border + subtle background shifts more than shadow for hierarchy
- Shadows should feel like absence of light, not presence of grey
- Glow effects replace traditional focus rings — they signal interactivity without breaking the dark aesthetic
- Never stack more than one shadow level on a single element
