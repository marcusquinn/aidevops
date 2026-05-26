<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Serper SERP data"
description: "Report presentation design system inspired by serper.dev."
colors:
  background: "#F8FBFF"
  surface: "#FFFFFF"
  on-surface: "#111827"
  muted: "#4B5563"
  outline: "#CBD5E1"
  primary: "#2563EB"
  primary-container: "#DBEAFE"
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
  md: 12px
  lg: 12px
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

# Design System: Serper SERP data

SERP/API data product. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: serper.dev
- **Accent**: `#2563EB` with supporting container `#DBEAFE`
- **Background/surface**: `#F8FBFF` / `#FFFFFF`
- **Text**: `#111827` primary, `#4B5563` secondary
- **Heading font**: Inter, system-ui, sans-serif
- **Body font**: Inter, system-ui, sans-serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 12px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://serper.dev
- **Fetched title/evidence**: Serper - The World's Fastest and Cheapest Google Search API
- **Fetch status**: Fetched https://serper.dev with status 200
- **Observed fonts**: -apple-system,BlinkMacSystemFont,Segoe UI,Noto Sans,Helvetica,Arial,sans-serif,Apple Color Emoji,Segoe UI Emoji, -apple-system,BlinkMacSystemFont,Segoe UI,Roboto,Oxygen,Ubuntu,Cantarell,Fira Sans,Droid Sans,Helvetica Neue,sans-serif, Apple Color Emoji,Segoe UI Emoji,Segoe UI Symbol, inherit, monospace, ui-monospace,SFMono-Regular,SF Mono,Menlo,Consolas,Liberation Mono,monospace
- **Observed colours**: #033a16, #0d1117, #1158c7, #161b22, #1f6feb, #21262d, #30363d, #484f58, #58a6ff, #5a1e02, #67060c, #6e7681
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
