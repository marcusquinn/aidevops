<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: IBM

IBM Carbon Design System — enterprise authority, monochromatic + blue, 8px grid, flat depth via background-color layering.

## Chapters

| File | Contents |
|------|----------|
| [01-visual-theme.md](01-visual-theme.md) | Visual identity, Carbon token system, key characteristics |
| [02-color-palette.md](02-color-palette.md) | Primary, neutral scale, interactive, status, dark theme |
| [03-typography.md](03-typography.md) | Font families, type scale table, typographic principles |
| [04-components.md](04-components.md) | Buttons, cards, inputs, navigation, links, distinctive components |
| [05-layout.md](05-layout.md) | Spacing system, grid, whitespace philosophy, border radius scale |
| [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels table, shadow philosophy |
| [07-dos-and-donts.md](07-dos-and-donts.md) | Do/Don't rules for Carbon compliance |
| [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, image behavior |
| [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example component prompts, iteration guide |

## Quick Reference

- **Accent**: IBM Blue 60 (`#0f62fe`) — the only chromatic hue
- **Background**: White (`#ffffff`) / Gray 10 (`#f4f4f4`) for cards
- **Text**: Gray 100 (`#161616`) primary, Gray 70 (`#525252`) secondary
- **Font**: IBM Plex Sans (300/400/600), IBM Plex Mono for code
- **Border-radius**: 0px everywhere except tags (24px pill)
- **Depth**: background-color layering, not shadows
- **Inputs**: bottom-border only (`2px solid #0f62fe` on focus)
- **Tokens**: `--cds-*` prefix for all semantic values
- **Grid**: 16-column, 8px base unit, 1584px max width
