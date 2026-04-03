# Design System: Corporate Traditional — Depth & Elevation

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Default state, inline elements |
| 1 | Raised | `0 1px 3px rgba(27, 54, 93, 0.06), 0 1px 2px rgba(27, 54, 93, 0.04)` | Cards, form containers |
| 2 | Elevated | `0 4px 12px rgba(27, 54, 93, 0.08), 0 2px 4px rgba(27, 54, 93, 0.04)` | Hover cards, popovers |
| 3 | Overlay | `0 12px 28px rgba(27, 54, 93, 0.12), 0 4px 8px rgba(27, 54, 93, 0.06)` | Modals, dropdown menus |
| 4 | Modal | `0 20px 40px rgba(27, 54, 93, 0.16), 0 8px 16px rgba(27, 54, 93, 0.08)` | Full-screen overlays |

**Elevation principles:**
- Use elevation sparingly — flat is the default
- Maximum two elevation levels visible simultaneously
- Never apply shadows to inline text elements
- Modal backdrop: `rgba(15, 35, 65, 0.5)`
