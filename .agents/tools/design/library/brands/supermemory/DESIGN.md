<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Supermemory gradient"
description: "Report presentation design system inspired by supermemory.ai."
colors:
  background: "#F8F7FF"
  surface: "#FFFFFF"
  on-surface: "#14112A"
  muted: "#5B5870"
  outline: "#DCD8F5"
  primary: "#6D28D9"
  primary-container: "#EEE7FF"
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
  md: 22px
  lg: 22px
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

# Design System: Supermemory gradient

personal AI gradient softness. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: supermemory.ai
- **Accent**: `#6D28D9` with supporting container `#EEE7FF`
- **Background/surface**: `#F8F7FF` / `#FFFFFF`
- **Text**: `#14112A` primary, `#5B5870` secondary
- **Heading font**: Inter, system-ui, sans-serif
- **Body font**: Inter, system-ui, sans-serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 22px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://supermemory.ai
- **Fetched title/evidence**: SupermemorySupermemory Context Stack
- **Fetch status**: Fetched https://supermemory.ai with status 200
- **Observed fonts**: DM Mono, DM Mono,monospace, DM Sans, Space Grotesk, Space Grotesk,sans-serif, var(--default-font-family,ui-sans-serif, system-ui, sans-serif, , var(--default-mono-font-family,ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, , var(--font-body)
- **Observed colours**: #000000, #007bff, #0452db, #051950, #0562ef, #0763ee, #0a0e13, #0b1015, #0d1117, #0f1117, #0f172a, #0f2660
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
