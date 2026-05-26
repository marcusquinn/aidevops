<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Posted App editorial"
description: "Report presentation design system inspired by postedapp.com."
colors:
  background: "#FFFDF8"
  surface: "#FFFFFF"
  on-surface: "#111111"
  muted: "#555555"
  outline: "#DDD6C8"
  primary: "#0F766E"
  primary-container: "#E0F2F1"
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
    fontFamily: 'Inter, system-ui, sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 14px
  lg: 14px
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

# Design System: Posted App editorial

publishing-oriented editorial UI. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: postedapp.com
- **Accent**: `#0F766E` with supporting container `#E0F2F1`
- **Background/surface**: `#FFFDF8` / `#FFFFFF`
- **Text**: `#111111` primary, `#555555` secondary
- **Heading font**: "Source Serif 4", Georgia, serif
- **Body font**: Inter, system-ui, sans-serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 14px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://postedapp.com
- **Fetched title/evidence**: Posted App | Viral Content Marketing Platform
- **Fetch status**: Fetched https://postedapp.com with status 200
- **Observed fonts**: Arial, Inter, Poppins, inter, poppins
- **Observed colours**: #00002e, #0000fe, #01081b, #02015a, #033bac, #111621, #2d354c, #38b3ff, #4e5774, #573cff, #68708c, #6b6b6b
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
