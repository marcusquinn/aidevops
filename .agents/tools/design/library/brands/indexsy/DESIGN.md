<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Indexsy agency"
description: "Report presentation design system inspired by indexsy.com."
colors:
  background: "#030712"
  surface: "#0B1020"
  on-surface: "#F9FAFB"
  muted: "#D7DBE3"
  outline: "#1A1F2E"
  primary: "#5270FF"
  primary-container: "#1A1F2E"
  background-dark: "#030712"
  surface-dark: "#0B1020"
  on-surface-dark: "#F9FAFB"
  muted-dark: "#D7DBE3"
  outline-dark: "#1A1F2E"
  primary-dark: "#5270FF"
  code-background: "#0B1020"
  code-on-background: "#F9FAFB"
  code-accent: "#93A3FF"
typography:
  headline-display:
    fontFamily: 'Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: 86px
    fontWeight: 500
    lineHeight: 1.02
    letterSpacing: -0.055em
  headline-md:
    fontFamily: 'Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: 42px
    fontWeight: 500
    lineHeight: 1.1
  body-md:
    fontFamily: 'Inter, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 28px
  lg: 32px
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

# Design System: Indexsy agency

Dark acquisition-agency landing page aesthetic with large white type, rounded glassy navigation/buttons, blue-violet CTAs, yellow numbered markers, and monochrome illustration energy. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: indexsy.com
- **Accent**: `#5270FF` / `#4721FB` button gradient direction, with yellow `#FFEB2D` step markers
- **Background/surface**: `#030712` / `#0B1020`
- **Text**: `#F9FAFB` primary, `#D7DBE3` secondary
- **Heading font**: Inter/system sans; use Instrument Serif only as an optional accent reference in bespoke layouts
- **Body font**: Inter/system sans-serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 28-32px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://indexsy.com
- **Fetched title/evidence**: Indexsy - We Build, Acquire & Scale Digital Assets
- **Fetch status**: Fetched https://indexsy.com with status 200
- **Observed fonts**: Inter, Instrument Serif, inherit, sans-serif, -apple-system/system-ui stacks
- **Observed colours**: #030712, #0B1020-derived dark surfaces, #3451EA, #4721FB, #5270FF, #F9FAFB, #D7DBE3, #FFFFFF; user screenshot also shows yellow numbered step markers
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
