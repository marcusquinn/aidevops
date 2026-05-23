<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Axel editorial evidence"
description: "Report presentation design system inspired by attached LLM Visibility Toolbox."
colors:
  background: "#FAFAF7"
  surface: "#FFFFFF"
  on-surface: "#0C0F15"
  muted: "#4B5563"
  outline: "#CDCFC9"
  primary: "#2D4BB5"
  primary-container: "#DBE1F2"
typography:
  headline-display:
    fontFamily: 'Newsreader, "Source Serif 4", Georgia, serif'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: 'Newsreader, "Source Serif 4", Georgia, serif'
    fontSize: 32px
    fontWeight: 650
    lineHeight: 1.15
  body-md:
    fontFamily: '"IBM Plex Sans", Inter, system-ui, sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", "SFMono-Regular", Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 18px
  lg: 18px
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

# Design System: Axel editorial evidence

near-white paper, evidence badges, sticky TOC, chaptered editorial report. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: attached LLM Visibility Toolbox
- **Accent**: `#2D4BB5` with supporting container `#DBE1F2`
- **Background/surface**: `#FAFAF7` / `#FFFFFF`
- **Text**: `#0C0F15` primary, `#4B5563` secondary
- **Heading font**: Newsreader, "Source Serif 4", Georgia, serif
- **Body font**: "IBM Plex Sans", Inter, system-ui, sans-serif
- **Code font**: "IBM Plex Mono", "JetBrains Mono", "SFMono-Regular", Consolas, monospace
- **Radius**: 18px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.
