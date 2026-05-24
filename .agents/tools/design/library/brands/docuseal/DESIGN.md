<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "DocuSeal product docs"
description: "Report presentation design system inspired by https://www.docuseal.com/."
colors:
  background: "#F8F4F1"
  surface: "#FFFFFF"
  on-surface: "#181818"
  muted: "#3F3F3F"
  outline: "#E3D8CE"
  primary: "#F59F5A"
  primary-container: "#FFE2C2"
  code-background: "#181818"
  code-on-background: "#F9FAFB"
  code-accent: "#F59F5A"
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

# Design System: DocuSeal product docs

warm open-source SaaS: off-white page, bold black typography, orange signature accent, pill CTAs, pale peach upload panels, restrained grey customer-logo tone, and simple rounded cards. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: https://www.docuseal.com/
- **Accent**: Orange `#F59F5A` with pale peach `#FFE2C2`; black text on warm off-white surfaces.
- **Background/surface**: `#F8F4F1` / `#FFFFFF`
- **Text**: `#181818` primary, `#3F3F3F` secondary
- **Heading font**: Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif
- **Body font**: Inter, ui-sans-serif, system-ui, -apple-system, "Segoe UI", sans-serif
- **Code font**: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace
- **Radius**: 20px
- **Mode**: light-first with accessible contrast adjustment
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-24
- **Source**: https://www.docuseal.com/
- **Fetched title/evidence**: DocuSeal | Open Source Document Signing
- **Fetch status**: Fetched and prompt-guard scanned clean.
- **Observed fonts**: Inter, ui-sans-serif/system stacks, ui-monospace/SFMono-Regular/Menlo/Consolas
- **Observed colours**: #181818, #F59F5A, #FFE2C2, #FFFFFF, #F8F4F1, #E3D8CE, #3F3F3F, #111827
- **Screenshot review**: user-provided screenshots were used for layout, contrast, and typography direction.
- **Rule**: source facts inform the DESIGN.md; renderer tokens are adjusted for report readability and WCAG contrast.
