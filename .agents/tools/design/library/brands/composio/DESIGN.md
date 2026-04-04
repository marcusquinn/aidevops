# Design System: Composio

Developer-focused dark UI system. Nocturnal command-center aesthetic with electric cyan accents on near-black canvas.

## Chapters

| # | File | Contents |
|---|------|----------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| 2 | [02-color-palette.md](02-color-palette.md) | Full color palette, roles, gradient system |
| 3 | [03-typography.md](03-typography.md) | Font families, hierarchy table, principles |
| 4 | [04-components.md](04-components.md) | Buttons, cards, inputs, nav, images, distinctive components |
| 5 | [05-layout.md](05-layout.md) | Spacing system, grid, whitespace, border radius scale |
| 6 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels, shadow philosophy, decorative depth |
| 7 | [07-dos-donts.md](07-dos-donts.md) | Do's and Don'ts reference |
| 8 | [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy |
| 9 | [09-agent-prompts.md](09-agent-prompts.md) | Quick color reference, example prompts, iteration guide |

## Quick Reference

**Palette essentials:**
- Background: `#0f0f0f` (Void Black)
- Brand: `#0007cd` (Composio Cobalt)
- Accent: `#00ffff` (Electric Cyan, use at 12% opacity for backgrounds)
- Text: `#ffffff` primary, `rgba(255,255,255,0.6)` secondary
- Borders: `rgba(255,255,255,0.04–0.12)` (Border Mist scale)

**Typography essentials:**
- Marketing: `abcDiatype` — weight 400, line-height 0.87–1.0 for headings
- Technical: `JetBrains Mono` — negative letter-spacing (-0.28px to -0.32px)

**Signature patterns:**
- Hard-offset brutalist shadow: `rgba(0,0,0,0.15) 4px 4px 0px 0px`
- Depth via border opacity, not box-shadow
- Uppercase + letter-spacing reserved for 12px overline labels only
