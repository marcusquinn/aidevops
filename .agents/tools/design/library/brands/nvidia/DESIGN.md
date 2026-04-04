# Design System: NVIDIA

Precision engineering aesthetic. High-contrast black/white foundation with NVIDIA Green (`#76b900`) as a pure signal accent — borders, underlines, highlights only, never fills.

## Chapters

| # | File | Contents |
|---|------|----------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| 2 | [02-color-palette.md](02-color-palette.md) | Full color palette, roles, interactive states |
| 3 | [03-typography.md](03-typography.md) | Font families, hierarchy table, principles |
| 4 | [04-components.md](04-components.md) | Buttons, cards, links, nav, images, distinctive components |
| 5 | [05-layout.md](05-layout.md) | Spacing system, grid, whitespace, border radius scale |
| 6 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels, shadow philosophy, decorative depth |
| 7 | [07-dos-donts.md](07-dos-donts.md) | Do's and Don'ts reference |
| 8 | [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, typography scaling |
| 9 | [09-agent-prompts.md](09-agent-prompts.md) | Quick color reference, example prompts, iteration guide |

## Quick Reference

**Palette essentials:**
- Background: `#000000` (True Black)
- Accent: `#76b900` (NVIDIA Green — borders, underlines, highlights only)
- Text dark bg: `#ffffff` primary, `#a7a7a7` secondary
- Text light bg: `#000000` primary, `#757575` secondary
- Link hover: `#3860be` (blue, universal)
- Button hover: `#1eaedb` (teal)

**Typography essentials:**
- Font: `NVIDIA-EMEA`, fallback `Arial, Helvetica, sans-serif`
- Headings: weight 700, line-height 1.25 (tight)
- Body: weight 400, line-height 1.50-1.67
- Navigation: 14px weight 700 uppercase

**Signature patterns:**
- Buttons: transparent background, `2px solid #76b900` border, 2px radius
- Border radius: 2px for everything (1px micro, 50% circles)
- Depth via color contrast (black/white sections), not shadow
- One shadow value: `rgba(0,0,0,0.3) 0px 0px 5px 0px`
