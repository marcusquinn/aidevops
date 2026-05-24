<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Apple HIG"
description: "Apple Human Interface Guidelines-inspired report presentation design system."
colors:
  background: "#F5F5F7"
  surface: "#FFFFFF"
  on-surface: "#1D1D1F"
  muted: "#6E6E73"
  outline: "#D2D2D7"
  primary: "#0066CC"
  primary-container: "#E8F2FF"
typography:
  headline-display:
    fontFamily: 'SF Pro Display, Inter, system-ui, sans-serif'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: 'SF Pro Display, Inter, system-ui, sans-serif'
    fontSize: 32px
    fontWeight: 650
    lineHeight: 1.15
  body-md:
    fontFamily: 'SF Pro Text, Inter, system-ui, sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: 'SF Mono, "IBM Plex Mono", monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 18px
  lg: 18px
---

# Design System: Apple

Reference corpus for Apple's web design system. Split into chapter files for progressive loading.

## Chapters

| # | File | Contents |
|---|------|----------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| 2 | [02-color-palette.md](02-color-palette.md) | Full color palette: primary, interactive, text, surfaces, shadows |
| 3 | [03-typography.md](03-typography.md) | Font families, type hierarchy table, typographic principles |
| 4 | [04-components.md](04-components.md) | Buttons, cards, navigation, images, distinctive components |
| 5 | [05-layout.md](05-layout.md) | Spacing system, grid, whitespace philosophy, border radius scale |
| 6 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels, shadow philosophy, decorative depth |
| 7 | [07-dos-and-donts.md](07-dos-and-donts.md) | Do's and Don'ts reference |
| 8 | [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, image behavior |
| 9 | [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example component prompts, iteration guide |

## Quick Reference

- **Primary accent**: Apple Blue `#0071e3` — interactive elements only
- **Backgrounds**: `#000000` (dark/immersive) alternating with `#f5f5f7` (light/informational)
- **Typography**: SF Pro Display (20px+) / SF Pro Text (below 20px) — optical sizing boundary
- **Pill CTA radius**: 980px — signature Apple link shape
- **Nav**: `rgba(0,0,0,0.8)` + `backdrop-filter: saturate(180%) blur(20px)` — non-negotiable glass effect

## Source Review

- **Review date**: 2026-05-23
- **Source**: https://developer.apple.com/design/human-interface-guidelines/typography
- **Fetched title/evidence**: Typography | Apple Developer Documentation
- **Fetch status**: Fetched https://developer.apple.com/design/human-interface-guidelines/typography with status 200
- **Observed fonts**: SF Mono,SFMono-Regular,ui-monospace,Menlo,monospace, SF Pro JP,SF Pro Text,SF Pro Icons,Hiragino Kaku Gothic Pro,ヒラギノ角ゴ Pro W3,メイリオ,Meiryo,ＭＳ Ｐゴシック,system-ui,-apple-system,BlinkMacSystemFont,Helvetica Neue,Helvetica,Arial,sans-serif, SF Pro KR,SF Pro Text,SF Pro Icons,Apple Gothic,HY Gulim,MalgunGothic,HY Dotum,Lexi Gulim,system-ui,-apple-system,BlinkMacSystemFont,Helvetica Neue,Helvetica,Arial,sans-serif, SF Pro SC,SF Pro Display,SF Pro Icons,PingFang SC,system-ui,-apple-system,BlinkMacSystemFont,Helvetica Neue,Helvetica,Arial,sans-serif, var(--typography-html-font,
- **Observed colours**: #001931, #002a51, #002b03, #002d2b, #002d75, #0071e3, #0077ed, #008009, #023b2d, #032603, #03638c, #03a10e
- **Light/dark mode**: observed theme/dark-mode markers in fetched HTML/CSS
- **Rule**: source facts inform the DESIGN.md; renderer tokens use accessible open-source/system substitutes where source fonts are commercial or unavailable.
