<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

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
