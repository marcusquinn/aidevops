<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Terminal Shop CLI"
description: "Report presentation design system inspired by www.terminal.shop/api."
colors:
  background: "#0B0F0C"
  surface: "#101810"
  on-surface: "#E6F6E6"
  muted: "#A7C7A7"
  outline: "#284A28"
  primary: "#4ADE80"
  primary-container: "#16321F"
typography:
  headline-display:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", monospace'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", monospace'
    fontSize: 32px
    fontWeight: 650
    lineHeight: 1.15
  body-md:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", monospace'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 8px
  lg: 8px
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

# Design System: Terminal Shop CLI

terminal-first API aesthetic. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: www.terminal.shop/api
- **Accent**: `#4ADE80` with supporting container `#16321F`
- **Background/surface**: `#0B0F0C` / `#101810`
- **Text**: `#E6F6E6` primary, `#A7C7A7` secondary
- **Heading font**: "IBM Plex Mono", "JetBrains Mono", monospace
- **Body font**: "IBM Plex Mono", "JetBrains Mono", monospace
- **Code font**: "IBM Plex Mono", "JetBrains Mono", monospace
- **Radius**: 8px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.
