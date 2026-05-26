<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Terminal Shop CLI"
description: "Report presentation design system inspired by https://www.terminal.shop/api."
colors:
  background: "#000000"
  surface: "#17191B"
  on-surface: "#FFFFFF"
  muted: "#BFBDB6"
  outline: "#3A3E41"
  primary: "#59C2FF"
  primary-container: "#1E2930"
  background-dark: "#000000"
  surface-dark: "#17191B"
  on-surface-dark: "#FFFFFF"
  muted-dark: "#BFBDB6"
  outline-dark: "#3A3E41"
  primary-dark: "#59C2FF"
  code-background: "#17191B"
  code-on-background: "#BFBDB6"
  code-accent: "#25D0AB"
typography:
  headline-display:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace'
    fontSize: 64px
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: -0.035em
  headline-md:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace'
    fontSize: 32px
    fontWeight: 700
    lineHeight: 1.15
  body-md:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.55
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
    rounded: "{rounded.lg}"
---

# Design System: Terminal Shop CLI

terminal API documentation: black page, dim grey navigation rails, monospaced lowercase prose, command palette colours for HTTP verbs, blue/yellow/green/red method accents, and flat rectangular code panels. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: https://www.terminal.shop/api
- **Accent**: Black terminal canvas with grey text and colourful method accents: blue GET, green POST, yellow PUT, red DELETE.
- **Background/surface**: `#000000` / `#17191B`
- **Text**: `#FFFFFF` primary, `#BFBDB6` secondary
- **Heading font**: "IBM Plex Mono", "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace
- **Body font**: "IBM Plex Mono", "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace
- **Code font**: "IBM Plex Mono", "JetBrains Mono", ui-monospace, SFMono-Regular, Menlo, monospace
- **Radius**: 2px
- **Mode**: dark-first with explicit dark tokens
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-24
- **Source**: https://www.terminal.shop/api
- **Fetched title/evidence**: wip: terminal (initial commit)
- **Fetch status**: Fetched and prompt-guard scanned clean.
- **Observed fonts**: Inter, mono
- **Observed colours**: #000000, #17191B, #3A3E41, #BFBDB6, #59C2FF, #25D0AB, #FFB800, #FF5E00, #E335D2
- **Screenshot review**: user-provided screenshots were used for layout, contrast, and typography direction.
- **Rule**: source facts inform the DESIGN.md; renderer tokens are adjusted for report readability and WCAG contrast.
