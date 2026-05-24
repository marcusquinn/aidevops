<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Polymarket Times"
description: "Report presentation design system inspired by https://www.polymarketimes.com/."
colors:
  background: "#F4F1EA"
  surface: "#FFFDF8"
  on-surface: "#1A1A1A"
  muted: "#374151"
  outline: "#000000"
  primary: "#008138"
  primary-container: "#E9E3D7"
  code-background: "#0A0A0A"
  code-on-background: "#FFFFFF"
  code-accent: "#05DF72"
  info-background: "#FFFDF8"
  impact-background: "#F4F1EA"
  evidence-background: "#FFFDF8"
  myth-background: "#F4F1EA"
  good-background: "#EEF8F0"
  bad-background: "#FFF0EE"
typography:
  headline-display:
    fontFamily: '"Playfair Display", Georgia, "Times New Roman", serif'
    fontSize: 72px
    fontWeight: 700
    lineHeight: 0.98
    letterSpacing: -0.035em
  headline-md:
    fontFamily: '"Playfair Display", Georgia, "Times New Roman", serif'
    fontSize: 36px
    fontWeight: 700
    lineHeight: 1.05
  body-md:
    fontFamily: 'Georgia, "Times New Roman", serif'
    fontSize: 17px
    fontWeight: 400
    lineHeight: 1.68
  code-md:
    fontFamily: 'Menlo, Monaco, "Courier New", monospace'
    fontSize: 13px
    fontWeight: 700
    lineHeight: 1.45
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

# Design System: Polymarket Times

Newspaper-style prediction-market editorial system inspired by The Polymarket Times. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

## Chapters

| File | Contents |
|------|----------|
| [01-visual-theme.md](01-visual-theme.md) | Visual identity, report mood, source inspiration |
| [02-color-palette.md](02-color-palette.md) | Accessible colour tokens and contrast guidance |
| [03-typography.md](03-typography.md) | Playfair Display, Georgia, and Menlo font mapping |
| [04-components.md](04-components.md) | Report cards, tables, evidence badges, callouts |
| [05-layout.md](05-layout.md) | Markdown-first HTML preview and PDF print layouts |
| [06-depth-elevation.md](06-depth-elevation.md) | Borders, surface layering, shadow discipline |
| [07-dos-and-donts.md](07-dos-and-donts.md) | Application rules and accessibility traps |
| [08-responsive.md](08-responsive.md) | Responsive HTML preview and PDF behaviour |
| [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Renderer handoff and prompt snippets |

## Quick Reference

- **Source inspiration**: https://www.polymarketimes.com/
- **Mood**: broadsheet newspaper, prediction-market ticker, cream newsprint, black rules, sharp editorial grid
- **Accent**: market green `#008138` / `#05DF72`; use red only for negative/down-market states
- **Background/surface**: `#F4F1EA` / `#FFFDF8`
- **Text**: `#1A1A1A` primary, `#374151` secondary
- **Heading font**: "Playfair Display", Georgia, "Times New Roman", serif
- **Body font**: Georgia, "Times New Roman", serif
- **Code/data/ticker font**: Menlo, Monaco, "Courier New", monospace
- **Radius**: 0px / square broadsheet panels
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-24
- **Source**: https://www.polymarketimes.com/
- **Fetched title/evidence**: Will Russia capture Lyman by December 31, 2026?... - The Polymarket Times
- **Fetch status**: Fetched https://www.polymarketimes.com/ with status 200; prompt-guard scan returned CLEAN.
- **Observed source colours**: `#F4F1EA`, `#1A1A1A`, `#000`, `#FFF` from fetched HTML/CSS.
- **Screenshot evidence**: user-provided screenshot shows cream newsprint background, black ticker/nav bars, green up-market indicators, red down-market indicators, Playfair Display masthead/headlines, Georgia article copy, and Menlo market/ticker UI.
- **Observed content cues**: masthead "The Polymarket Times", late city edition timestamp, all-caps section navigation, market ticker, category lozenges, thick horizontal rules, monochrome imagery, dotted table/list separators.
- **Rule**: source facts and user-provided screenshot inform the DESIGN.md; renderer tokens are adjusted for report readability, local font fallbacks, and WCAG contrast.
