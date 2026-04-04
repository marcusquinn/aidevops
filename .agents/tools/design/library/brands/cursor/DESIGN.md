<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Cursor

Reference corpus for Cursor's design language. Each chapter is a self-contained reference file.

## Chapters

| # | File | Contents |
|---|------|----------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Warm minimalism aesthetic, typography signature, border system, key characteristics |
| 2 | [02-color-palette.md](02-color-palette.md) | Primary, accent, semantic, timeline, surface scale, border colors, shadows |
| 3 | [03-typography.md](03-typography.md) | Font families, type hierarchy table, typographic principles |
| 4 | [04-components.md](04-components.md) | Buttons (5 variants), cards, inputs, navigation, image treatment, distinctive components |
| 5 | [05-layout.md](05-layout.md) | Spacing system, grid/container, whitespace philosophy, border radius scale |
| 6 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation scale table, shadow philosophy, decorative depth |
| 7 | [07-interaction-motion.md](07-interaction-motion.md) | Hover states, focus states, transitions |
| 8 | [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, image behavior |
| 9 | [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example component prompts, iteration guide |

## Quick Reference

**Palette essentials:**

- Background: `#f2f1ed` (warm cream)
- Text: `#26251e` (warm near-black)
- Accent: `#f54e00` (orange)
- Error/hover: `#cf2d56` (warm crimson)
- Border: `oklab(0.263084 -0.00230259 0.0124794 / 0.1)` (perceptually uniform warm brown)

**Typography:**

- Display: CursorGothic, -2.16px tracking at 72px
- Body: jjannon serif with `"cswh"` OpenType feature
- Code: berkeleyMono

**Spacing:** 8px base; sub-8px fine scale (1.5, 2, 2.5, 3, 4, 5, 6px)

**Radius:** 8px standard; 9999px full-pill for tags/filters
