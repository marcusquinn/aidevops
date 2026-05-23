<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "arXiv academic"
description: "Report presentation design system inspired by arxiv.org academic papers."
colors:
  background: "#FFFFFF"
  surface: "#FFFFFF"
  on-surface: "#111111"
  muted: "#4B5563"
  outline: "#CFCFCF"
  primary: "#8B1A1A"
  primary-container: "#F4E8E8"
typography:
  headline-display:
    fontFamily: '"Source Serif 4", "Libre Baskerville", Georgia, "Times New Roman", serif'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: '"Source Serif 4", "Libre Baskerville", Georgia, "Times New Roman", serif'
    fontSize: 32px
    fontWeight: 650
    lineHeight: 1.15
  body-md:
    fontFamily: '"Source Serif 4", Georgia, serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", "SFMono-Regular", Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 2px
  lg: 2px
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

# Design System: arXiv academic

academic paper density, restrained rules, citation-forward typography. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: arxiv.org academic papers
- **Accent**: `#8B1A1A` with supporting container `#F4E8E8`
- **Background/surface**: `#FFFFFF` / `#FFFFFF`
- **Text**: `#111111` primary, `#4B5563` secondary
- **Heading font**: "Source Serif 4", "Libre Baskerville", Georgia, "Times New Roman", serif
- **Body font**: "Source Serif 4", Georgia, serif
- **Code font**: "IBM Plex Mono", "SFMono-Regular", Consolas, monospace
- **Radius**: 2px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://arxiv.org
- **Fetched title/evidence**: arXiv.org e-Print archivecontact arXivsubscribe to arXiv mailings
- **Fetch status**: Fetched https://arxiv.org with status 200
- **Observed fonts**: EB Garamond, Lucida Grande, courier, inherit, monospace, verdana, arial, helvetica, sans-serif
- **Observed colours**: #000000, #0012ef, #005909, #005aa7, #005e9d, #005ea2, #0068AC, #009917, #046BAF, #046baf, #054169, #1772a0
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
