<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# terminalshop: Colour Palette

## Observed/source-informed colours

- `#000000`
- `#17191B`
- `#3A3E41`
- `#BFBDB6`
- `#59C2FF`
- `#25D0AB`
- `#FFB800`
- `#FF5E00`
- `#E335D2`

## Semantic report mapping

- `#000000` — background
- `#17191B` — surface
- `#FFFFFF` — on-surface
- `#BFBDB6` — muted
- `#3A3E41` — outline
- `#59C2FF` — primary
- `#1E2930` — primary-container
- `#17191B` — code-background
- `#BFBDB6` — code-on-background
- `#25D0AB` — code-accent

## Application rules

- Use source colours as evidence, then map into semantic DESIGN.md roles.
- Adjust brightness when required for readable long-form reports and WCAG contrast.
- Long-form text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve labels and borders so grayscale PDF output remains meaningful.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
