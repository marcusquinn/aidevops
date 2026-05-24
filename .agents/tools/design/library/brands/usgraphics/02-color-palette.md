<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# usgraphics: Colour Palette

## Observed/source-informed colours

- `#002DCE`
- `#000000`
- `#FFFFFF`
- `#9A9A9A`
- `#E6E6E6`
- `#FFCC00`
- `#00A96C`
- `#E335D2`

## Semantic report mapping

- `#F3F3F0` — background
- `#FFFFFF` — surface
- `#111111` — on-surface
- `#555555` — muted
- `#9A9A9A` — outline
- `#002DCE` — primary
- `#E7ECFF` — primary-container
- `#F7F7F7` — code-background
- `#111111` — code-on-background
- `#002DCE` — code-accent

## Application rules

- Use source colours as evidence, then map into semantic DESIGN.md roles.
- Adjust brightness when required for readable long-form reports and WCAG contrast.
- Long-form text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve labels and borders so grayscale PDF output remains meaningful.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
