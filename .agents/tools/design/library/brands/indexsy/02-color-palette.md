<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# indexsy: Colour Palette

## Observed source colours

- `#030712`
- `#1A1F2E`
- `#3451ea`
- `#4721FB`
- `#5270ff`
- `#D7DBE3`
- `#F9FAFB`
- `#FFFFFF`
- Yellow numbered step markers are visible in the reviewed screenshot; use `#FFEB2D` as the report approximation.

## Semantic token mapping

| Role | Value | Use |
|------|-------|-----|
| Background | `#030712` | report page and hero field |
| Surface | `#0B1020` | cards, TOC, code boxes, diagram panels |
| Text | `#F9FAFB` | long-form text and headings |
| Muted text | `#D7DBE3` | secondary copy and captions |
| Primary | `#5270FF` | links, focus, active TOC, CTA affordances |
| CTA/depth | `#4721FB` | rounded button/pill fills |
| Step accent | `#FFEB2D` | numbered markers and selected counters |

## Application rules

- Use the dark palette by default. Do not keep the previous orange/light agency approximation for Indexsy reports.
- Long-form report text must use high-contrast `on-surface`; reserve violet/blue for links, buttons, active states, and borders.
- Badge/status colours must preserve text labels and borders so grayscale PDF output remains meaningful.
- For missing theme modes, calculate inverse roles with `colour-palette.md`; mark them as derived until previewed and contrast-checked.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
