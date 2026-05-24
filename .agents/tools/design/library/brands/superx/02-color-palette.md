<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# superx: Colour Palette

## Observed/source-informed colours

- `#0F0F0F`
- `#181818`
- `#1F1F1F`
- `#333333`
- `#FC8A65`
- `#E05C2A`
- `#FFC35B`
- `#FFFFFF`
- `#B1B1B1`

## Semantic report mapping

- `#0F0F0F` — background
- `#181818` — surface
- `#FFFFFF` — on-surface
- `#B1B1B1` — muted
- `#333333` — outline
- `#FC8A65` — primary
- `#351D10` — primary-container
- `#111111` — code-background
- `#F5F5F5` — code-on-background
- `#FFC35B` — code-accent

## Application rules

- Use source colours as evidence, then map into semantic DESIGN.md roles.
- Adjust brightness when required for readable long-form reports and WCAG contrast.
- Long-form text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve labels and borders so grayscale PDF output remains meaningful.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
