<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "IBM Carbon"
description: "IBM Carbon-inspired report presentation design system."
colors:
  background: "#F4F4F4"
  surface: "#FFFFFF"
  on-surface: "#161616"
  muted: "#525252"
  outline: "#C6C6C6"
  primary: "#0F62FE"
  primary-container: "#D0E2FF"
typography:
  headline-display:
    fontFamily: '"IBM Plex Sans", Inter, system-ui, sans-serif'
    fontSize: 64px
    fontWeight: 300
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: '"IBM Plex Sans", Inter, system-ui, sans-serif'
    fontSize: 32px
    fontWeight: 400
    lineHeight: 1.15
  body-md:
    fontFamily: '"IBM Plex Sans", Inter, system-ui, sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 0px
  lg: 0px
---

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

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://www.ibm.com/design/language/
- **Fetched title/evidence**: (title unavailable)
- **Fetch status**: Fetched https://www.ibm.com/design/language/ with status 200
- **Observed fonts**: Arial, Helvetica, IBM Plex, Mono, inter, mono
- **Observed colours**: #002d9c, #003a6d, #004144, #0043ce, #0353e9, #044317, #0f62fe, #161616, #198038, #262626, #2c2c2c, #343a3f
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
