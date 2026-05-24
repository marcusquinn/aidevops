<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "US Graphics catalogue"
description: "Report presentation design system inspired by https://usgraphics.com/catalog."
colors:
  background: "#F3F3F0"
  surface: "#FFFFFF"
  on-surface: "#111111"
  muted: "#555555"
  outline: "#9A9A9A"
  primary: "#002DCE"
  primary-container: "#E7ECFF"
  code-background: "#F7F7F7"
  code-on-background: "#111111"
  code-accent: "#002DCE"
typography:
  headline-display:
    fontFamily: '"Univers LT Pro Condensed", "Arial Narrow", "Roboto Condensed", Arial, sans-serif'
    fontSize: 64px
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: -0.035em
  headline-md:
    fontFamily: '"Univers LT Pro Condensed", "Arial Narrow", "Roboto Condensed", Arial, sans-serif'
    fontSize: 32px
    fontWeight: 700
    lineHeight: 1.15
  body-md:
    fontFamily: '"IoskeleyMono", Menlo, Monaco, Consolas, monospace'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IoskeleyMono", Menlo, Monaco, Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.55
rounded:
  md: 0px
  lg: 0px
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

# Design System: US Graphics catalogue

dense utilitarian catalogue: white/grey canvas, blue underlined masthead, Univers LT Pro Condensed-like headings, mono/data body rhythm, thin black rules, flat boxes, colour-chip palette strips, and almost-square corners. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: https://usgraphics.com/catalog
- **Accent**: Blue `#002DCE` link masthead, white/grey industrial surfaces, black rules, and flat colour-chip accents.
- **Background/surface**: `#F3F3F0` / `#FFFFFF`
- **Text**: `#111111` primary, `#555555` secondary
- **Heading font**: "Univers LT Pro Condensed", "Arial Narrow", "Roboto Condensed", Arial, sans-serif
- **Body font**: "IoskeleyMono", Menlo, Monaco, Consolas, monospace
- **Code font**: "IoskeleyMono", Menlo, Monaco, Consolas, monospace
- **Radius**: 0px
- **Mode**: light-first with accessible contrast adjustment
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-24
- **Source**: https://usgraphics.com/catalog
- **Fetched title/evidence**: U.S. Graphics Company - General Catalog
- **Fetch status**: Fetched and prompt-guard scanned clean.
- **Observed fonts**: Univers LT Pro Condensed Regular/Bold, TX 02 Data Regular, SF Mono, IoskeleyMono suggestion for report-compatible body/code
- **Observed colours**: #002DCE, #000000, #FFFFFF, #9A9A9A, #E6E6E6, #FFCC00, #00A96C, #E335D2
- **Screenshot review**: user-provided screenshots were used for layout, contrast, and typography direction.
- **Rule**: source facts inform the DESIGN.md; renderer tokens are adjusted for report readability and WCAG contrast.
