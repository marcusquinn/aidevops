<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Times newspaper"
description: "Report presentation design system inspired by polymarketimes.com."
colors:
  background: "#F7F2E8"
  surface: "#FFFDF8"
  on-surface: "#111111"
  muted: "#525252"
  outline: "#C8BFAE"
  primary: "#8A2C2C"
  primary-container: "#F0E1D8"
typography:
  headline-display:
    fontFamily: '"Source Serif 4", Georgia, serif'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: '"Source Serif 4", Georgia, serif'
    fontSize: 32px
    fontWeight: 650
    lineHeight: 1.15
  body-md:
    fontFamily: '"Source Serif 4", Georgia, serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 4px
  lg: 4px
spacing:
  md: 16px
  lg: 24px
  xl: 32px
components:
  report-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
    borderWidth: 1
  evidence-badge:
    backgroundColor: "{colors.primary-container}"
    textColor: "{colors.on-surface}"
    rounded: 999px
---

# Design System: Times newspaper

newspaper-style editorial hierarchy. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

## Chapters

| File | Contents |
|------|----------|
| [01-visual-theme.md](01-visual-theme.md) | Visual identity, report mood, source inspiration |
| [02-color-palette.md](02-color-palette.md) | Accessible colour tokens and contrast guidance |
| [03-typography.md](03-typography.md) | Open-source/system font substitutes and type scale |
| [04-components.md](04-components.md) | Report cards, tables, evidence badges, callouts |
| [05-layout.md](05-layout.md) | Markdown-first HTML preview and PDF print layouts |
| [06-depth-elevation.md](06-depth-elevation.md) | Borders, surface layering, shadow discipline |
| [07-dos-and-donts.md](07-dos-and-donts.md) | Application rules and accessibility traps |
| [08-responsive.md](08-responsive.md) | Responsive HTML preview and PDF behaviour |
| [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Renderer handoff and prompt snippets |

## Quick Reference

- **Source inspiration**: polymarketimes.com
- **Accent**: `#8A2C2C` with supporting container `#F0E1D8`
- **Background/surface**: `#F7F2E8` / `#FFFDF8`
- **Text**: `#111111` primary, `#525252` secondary
- **Heading font**: "Source Serif 4", Georgia, serif
- **Body font**: "Source Serif 4", Georgia, serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 4px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.
