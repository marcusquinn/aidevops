<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Outrank SEO"
description: "Report presentation design system inspired by Outrank-style SEO reporting."
colors:
  background: "#F8FAFC"
  surface: "#FFFFFF"
  on-surface: "#0F172A"
  muted: "#475569"
  outline: "#CBD5E1"
  primary: "#EA580C"
  primary-container: "#FFEDD5"
typography:
  headline-display:
    fontFamily: 'Inter, system-ui, sans-serif'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: 'Inter, system-ui, sans-serif'
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
  md: 16px
  lg: 16px
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

# Design System: Outrank SEO

SEO report energy with orange priority accent. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: Outrank-style SEO reporting
- **Accent**: `#EA580C` with supporting container `#FFEDD5`
- **Background/surface**: `#F8FAFC` / `#FFFFFF`
- **Text**: `#0F172A` primary, `#475569` secondary
- **Heading font**: Inter, system-ui, sans-serif
- **Body font**: Inter, system-ui, sans-serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 16px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: 
- **Fetched title/evidence**: (title unavailable)
- **Fetch status**: Fetch incomplete for outrank: unknown error
- **Observed fonts**: not available from fetched markup/CSS
- **Observed colours**: not available from fetched markup/CSS
- **Light/dark mode**: not observed in fetched HTML/CSS; inverse mode should be derived and contrast-checked
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
