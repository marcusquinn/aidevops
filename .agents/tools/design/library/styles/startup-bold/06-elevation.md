<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Startup Bold — Depth & Elevation

| Level | Name | Shadow Value | Usage |
|-------|------|-------------|-------|
| 0 | Flat | `none` | Default state, elements on coloured backgrounds |
| 1 | Resting | `0 1px 3px rgba(0, 0, 0, 0.06)` | Cards at rest, nav bar |
| 2 | Raised | `0 4px 16px rgba(0, 0, 0, 0.08)` | Hover cards, dropdowns |
| 3 | Elevated | `0 8px 32px rgba(0, 0, 0, 0.1)` | Popovers, tooltips |
| 4 | Overlay | `0 16px 48px rgba(0, 0, 0, 0.12)` | Modals, full overlays |
| Glow | Primary | `0 4px 16px rgba(79, 70, 229, 0.25)` | Primary CTA hover emphasis |
| Glow | Accent | `0 4px 16px rgba(16, 185, 129, 0.2)` | Accent CTA hover emphasis |

**Elevation principles:**

- Resting state (level 1) gives all cards a subtle groundedness — nothing floats without context
- Hover reveals higher elevation (1 → 2) with smooth transition
- Coloured glow shadows are reserved for CTA buttons only — not cards or containers
- Modals get level 4 plus a semi-transparent overlay backdrop (`rgba(0,0,0,0.4)`)
- Shadow transitions should always animate (200ms ease-out)
