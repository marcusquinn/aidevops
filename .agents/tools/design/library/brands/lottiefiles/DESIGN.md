<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "LottieFiles motion"
description: "Report presentation design system inspired by lottiefiles.com."
colors:
  background: "#FFFFFF"
  surface: "#FFFFFF"
  on-surface: "#18181B"
  muted: "#4C5863"
  outline: "#E4EAED"
  primary: "#019D91"
  primary-container: "#DDFBF5"
  background-dark: "#080A0C"
  surface-dark: "#161A1C"
  on-surface-dark: "#FFFFFF"
  muted-dark: "#BFC8D1"
  outline-dark: "#222A30"
  primary-dark: "#00DDB3"
typography:
  headline-display:
    fontFamily: '"DM Sans", Inter, system-ui, sans-serif'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: '"DM Sans", Inter, system-ui, sans-serif'
    fontSize: 32px
    fontWeight: 650
    lineHeight: 1.15
  body-md:
    fontFamily: '"DM Sans", Inter, system-ui, sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
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
    rounded: 999px
---

# Design System: LottieFiles motion

motion design freshness. This DESIGN.md is a report-presentation brand preset for Markdown-first HTML previews and PDF deliverables.

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

- **Source inspiration**: lottiefiles.com
- **Accent**: `#019D91` with supporting container `#DDFBF5`; dark accent observed as `#00DDB3`
- **Background/surface**: `#FFFFFF` / `#FFFFFF`; dark inverse observed as `#080A0C` / `#161A1C`
- **Text**: `#18181B` primary, `#4C5863` secondary; dark text observed as `#FFFFFF` / `#BFC8D1`
- **Heading font**: DM Sans, Inter, system UI
- **Body font**: DM Sans, Inter, system UI
- **Code font**: UI monospace stack
- **Radius**: 20px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://lottiefiles.com
- **Fetched title/evidence**: saved Brave page title `LottieFiles: Download Free lightweight animations for website & apps.`; hero text includes `Great designs come alive with motion!`
- **Fetch status**: user-saved complete page and assets inspected from Downloads after unauthenticated headless fetch returned anti-bot/challenge content.
- **Browser automation**: saved-page asset extraction from `app-CcHwpV-Z.css`, `app-Bm8_5TZU.css`, and `757b0c28c29ef841.css`; previous Brave tab title/URL query confirmed live page.
- **Observed fonts**: Inter, DM Sans, Noto Sans JP, Noto Sans KR, Pretendard, arboria, karla, UI monospace stack
- **Observed colours**: `--action-primary:#019d91`, `--action-primary-hover:#00c1a2`, `--action-focus:#00ddb3`, `--background:oklch(100% 0 0)`, dark `--background:oklch(14.1% .005 285.823)`, `#18181B`, `#4c5863`, `#e4eaed`, `#080a0c`, `#161a1c`, `#bfc8d1`
- **Light/dark mode**: saved CSS contains paired light/dark token values and theme variables; use observed inverse roles before deriving fallbacks.
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
