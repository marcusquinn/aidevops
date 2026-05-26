<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "ExSqueezeMe macOS video"
description: "Report presentation design system inspired by https://exsqueezeme.app/."
colors:
  background: "#0A0A0A"
  surface: "#111111"
  on-surface: "#FFFFFF"
  muted: "#E0E0E0"
  outline: "#FFFFFF"
  primary: "#FF5F1F"
  primary-container: "#1F1F1F"
  background-dark: "#0A0A0A"
  surface-dark: "#111111"
  on-surface-dark: "#FFFFFF"
  muted-dark: "#E0E0E0"
  outline-dark: "#FFFFFF"
  primary-dark: "#FF5F1F"
  code-background: "#111111"
  code-on-background: "#FFFFFF"
  code-accent: "#FF5F1F"
typography:
  headline-display:
    fontFamily: 'Space Grotesk, Inter, ui-sans-serif, system-ui, sans-serif'
    fontSize: 64px
    fontWeight: 800
    lineHeight: 1.02
    letterSpacing: -0.045em
  headline-md:
    fontFamily: 'Space Grotesk, Inter, ui-sans-serif, system-ui, sans-serif'
    fontSize: 32px
    fontWeight: 800
    lineHeight: 1.08
  body-md:
    fontFamily: 'Space Mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: 'Space Mono, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace'
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
    borderWidth: 2
  evidence-badge:
    backgroundColor: "{colors.primary-container}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
---

# Design System: ExSqueezeMe macOS video

Hard-edged black/orange macOS utility marketing: black dotted canvas, giant uppercase white display type, orange slab highlight bars, Space Grotesk/Space Mono feel, white outlined buttons, offset white shadows, and square card geometry. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: https://exsqueezeme.app/
- **Accent**: orange `#FF5F1F` slab CTAs on black `#0A0A0A`
- **Background/surface**: `#0A0A0A` / `#111111`
- **Text**: `#FFFFFF` primary, `#E0E0E0` secondary
- **Heading font**: Space Grotesk, Inter, system sans-serif
- **Body/code font**: Space Mono, system monospace
- **Radius**: 0px / square
- **Mode**: dark-first with explicit dark tokens
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-24
- **Source**: https://exsqueezeme.app/
- **Fetched title/evidence**: ExSqueezeMe - macOS video reframing and compression made simple
- **Fetch status**: Fetched and prompt-guard scanned clean.
- **Observed fonts**: screenshot shows Space Grotesk-like display and Space Mono-like support copy; prior fetch evidence included Space Grotesk and Space Mono references.
- **Observed colours**: screenshot shows `#0A0A0A` black, white, orange `#FF5F1F`, dark panels, dotted grid.
- **Screenshot review**: user-provided screenshot used for layout, contrast, square borders, orange slabs, and offset shadow direction.
- **Rule**: source facts inform the DESIGN.md; renderer tokens are adjusted for report readability and WCAG contrast.
