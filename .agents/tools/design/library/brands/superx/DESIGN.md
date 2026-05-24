<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "SuperX social analytics"
description: "Report presentation design system inspired by https://superx.so/."
colors:
  background: "#0F0F0F"
  surface: "#181818"
  on-surface: "#FFFFFF"
  muted: "#B1B1B1"
  outline: "#333333"
  primary: "#FC8A65"
  primary-container: "#351D10"
  background-dark: "#0F0F0F"
  surface-dark: "#181818"
  on-surface-dark: "#FFFFFF"
  muted-dark: "#B1B1B1"
  outline-dark: "#333333"
  primary-dark: "#FC8A65"
  code-background: "#111111"
  code-on-background: "#F5F5F5"
  code-accent: "#FFC35B"
typography:
  headline-display:
    fontFamily: 'Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif'
    fontSize: 64px
    fontWeight: 700
    lineHeight: 1.08
    letterSpacing: -0.035em
  headline-md:
    fontFamily: 'Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif'
    fontSize: 32px
    fontWeight: 700
    lineHeight: 1.15
  body-md:
    fontFamily: 'Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.55
rounded:
  md: 20px
  lg: 20px
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

# Design System: SuperX social analytics

dark social-growth SaaS: near-black canvas, smoky glass panels, warm orange flame gradient, muted grey nav, rounded CTA buttons, glowing product screenshot cards, and high-contrast white metrics. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: https://superx.so/
- **Accent**: Dark `#0F0F0F` / `#181818` surfaces with orange `#FC8A65` and amber `#FFC35B` accents.
- **Background/surface**: `#0F0F0F` / `#181818`
- **Text**: `#FFFFFF` primary, `#B1B1B1` secondary
- **Heading font**: Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif
- **Body font**: Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif
- **Code font**: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace
- **Radius**: 20px
- **Mode**: dark-first with explicit dark tokens
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-24
- **Source**: https://superx.so/
- **Fetched title/evidence**: SuperX | X Growth Tool: Scheduling, Analytics, AI Content
- **Fetch status**: Fetched and prompt-guard scanned clean.
- **Observed fonts**: Inter, Instrument Serif accent references, ui-monospace/SFMono-Regular/Menlo/Consolas
- **Observed colours**: #0F0F0F, #181818, #1F1F1F, #333333, #FC8A65, #E05C2A, #FFC35B, #FFFFFF, #B1B1B1
- **Screenshot review**: user-provided screenshots were used for layout, contrast, and typography direction.
- **Rule**: source facts inform the DESIGN.md; renderer tokens are adjusted for report readability and WCAG contrast.
