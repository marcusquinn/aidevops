<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Zeroheight design docs"
description: "Report presentation design system inspired by zeroheight.com."
colors:
  background: "#FAFAFC"
  surface: "#FFFFFF"
  on-surface: "#171717"
  muted: "#52525B"
  outline: "#E4E4E7"
  primary: "#7C3AED"
  primary-container: "#F0E7FF"
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

# Design System: Zeroheight design docs

design documentation system. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: zeroheight.com
- **Accent**: `#7C3AED` with supporting container `#F0E7FF`
- **Background/surface**: `#FAFAFC` / `#FFFFFF`
- **Text**: `#171717` primary, `#52525B` secondary
- **Heading font**: Inter, system-ui, sans-serif
- **Body font**: Inter, system-ui, sans-serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 16px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://zeroheight.com
- **Fetched title/evidence**: zeroheight - The Design System Platform Built for the AI Era
- **Fetch status**: Fetched https://zeroheight.com with status 200
- **Observed fonts**: inherit, var(--default-font-family,ui-sans-serif,system-ui,sans-serif,, var(--default-mono-font-family,ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,, var(--font-body), var(--font-heading), var(--font-inter), var(--font-mono), var(--font-sans)
- **Observed colours**: #000000, #000001, #00CA4E, #00CBA0, #00ca4e, #00cba0, #050505, #0A0A0A, #0a0a0a, #151316, #1A1A1A, #1C1C1C
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
