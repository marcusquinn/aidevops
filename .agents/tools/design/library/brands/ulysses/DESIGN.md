<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Ulysses app editorial"
description: "Report presentation design system inspired by https://ulysses.app/."
colors:
  background: "#FFFFFF"
  surface: "#FFFFFF"
  on-surface: "#27272B"
  muted: "#5F5F63"
  outline: "#E5E5E5"
  primary: "#F7C600"
  primary-container: "#FFF4BF"
  code-background: "#2F2F2F"
  code-on-background: "#F7F7F7"
  code-accent: "#F7C600"
typography:
  headline-display:
    fontFamily: 'Interstate, "Avenir Next", "Helvetica Neue", Arial, sans-serif'
    fontSize: 64px
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: -0.035em
  headline-md:
    fontFamily: 'Interstate, "Avenir Next", "Helvetica Neue", Arial, sans-serif'
    fontSize: 32px
    fontWeight: 700
    lineHeight: 1.15
  body-md:
    fontFamily: 'Interstate, "Avenir Next", "Helvetica Neue", Arial, sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: 'Menlo, Monaco, Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.55
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
    rounded: "{rounded.lg}"
---

# Design System: Ulysses app editorial

Apple-like writing app marketing: bright white hero, clean black typography, yellow butterfly/accent, grey editorial sections, subtle UI chrome, and an Interstate-like grotesk tone. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: https://ulysses.app/
- **Accent**: White UI surfaces, black text, yellow `#F7C600` accent, and dark grey feature sections.
- **Background/surface**: `#FFFFFF` / `#FFFFFF`
- **Text**: `#27272B` primary, `#5F5F63` secondary
- **Heading font**: Interstate, "Avenir Next", "Helvetica Neue", Arial, sans-serif
- **Body font**: Interstate, "Avenir Next", "Helvetica Neue", Arial, sans-serif
- **Code font**: Menlo, Monaco, Consolas, monospace
- **Radius**: 8px
- **Mode**: light-first with accessible contrast adjustment
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-24
- **Source**: https://ulysses.app/
- **Fetched title/evidence**: Ulysses
- **Fetch status**: Fetched and prompt-guard scanned clean.
- **Observed fonts**: Interstate-style UI lettering from screenshot, system sans fallbacks, Menlo/Monaco for code
- **Observed colours**: #FFFFFF, #27272B, #F7C600, #333333, #F2F2F2, #5F5F63
- **Screenshot review**: user-provided screenshots were used for layout, contrast, and typography direction.
- **Rule**: source facts inform the DESIGN.md; renderer tokens are adjusted for report readability and WCAG contrast.
