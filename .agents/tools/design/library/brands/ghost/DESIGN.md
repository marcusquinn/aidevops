<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Ghost documentation"
description: "Report presentation design system inspired by docs.ghost.org."
colors:
  background: "#F8FAFC"
  surface: "#FFFFFF"
  on-surface: "#15171A"
  muted: "#4B5563"
  outline: "#DDE3EA"
  primary: "#30CF43"
  primary-container: "#E8FBEA"
typography:
  headline-display:
    fontFamily: 'Inter, "IBM Plex Sans", system-ui, sans-serif'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: 'Inter, "IBM Plex Sans", system-ui, sans-serif'
    fontSize: 32px
    fontWeight: 650
    lineHeight: 1.15
  body-md:
    fontFamily: 'Inter, "IBM Plex Sans", system-ui, sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 14px
  lg: 14px
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

# Design System: Ghost documentation

clean documentation surfaces and green product accent. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: docs.ghost.org
- **Accent**: `#30CF43` with supporting container `#E8FBEA`
- **Background/surface**: `#F8FAFC` / `#FFFFFF`
- **Text**: `#15171A` primary, `#4B5563` secondary
- **Heading font**: Inter, "IBM Plex Sans", system-ui, sans-serif
- **Body font**: Inter, "IBM Plex Sans", system-ui, sans-serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 14px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://docs.ghost.org
- **Fetched title/evidence**: Getting Started With Ghost - Ghost Developer Docs
- **Fetch status**: Fetched https://docs.ghost.org with status 200
- **Observed fonts**: CMU Typewriter Text, CMU Typewriter Text!important, Inter, Inter Fallback, Inter,Inter Fallback,-apple-system,BlinkMacSystemFont,Segoe UI,system-ui,sans-serif, JetBrains Mono, JetBrains Mono Fallback, JetBrains Mono,JetBrains Mono Fallback,SF Mono,SFMono-Regular,Menlo,Monaco,Cascadia Mono,Segoe UI Mono,Roboto Mono,Oxygen Mono,Ubuntu Monospace,Source Code Pro,Fira Mono,Droid Sans Mono,Consolas,Courier New,monospace
- **Observed colours**: #000000, #00A63E, #00c951, #00d3f2, #03153A, #072213, #07296A, #084608, #09090B, #0B0C0E, #0F1117, #0F4C2C
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
