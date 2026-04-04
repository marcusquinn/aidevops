<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Corporate Friendly — Depth & Elevation

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Default state, borders handle separation |
| 1 | Raised | `0 1px 3px rgba(0, 0, 0, 0.04), 0 1px 2px rgba(0, 0, 0, 0.03)` | Cards at rest |
| 2 | Elevated | `0 8px 24px rgba(0, 0, 0, 0.06), 0 2px 6px rgba(0, 0, 0, 0.03)` | Hover cards, active components |
| 3 | Overlay | `0 12px 32px rgba(0, 0, 0, 0.08), 0 4px 12px rgba(0, 0, 0, 0.04)` | Dropdowns, popovers, tooltips |
| 4 | Modal | `0 24px 48px rgba(0, 0, 0, 0.12), 0 8px 24px rgba(0, 0, 0, 0.06)` | Modal dialogs |

**Elevation principles:**

- Shadows are always neutral black-based (`rgba(0,0,0,...)`) for warmth
- Cards hover upward with `transform: translateY(-2px)` paired with level 2 shadow
- Shadows increase gradually — no harsh jumps between levels
- Modal backdrop: `rgba(0, 0, 0, 0.3)` — lighter than typical, keeping the friendly feel
