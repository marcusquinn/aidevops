<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# ulysses: Colour Palette

## Observed/source-informed colours

- `#FFFFFF`
- `#27272B`
- `#F7C600`
- `#333333`
- `#F2F2F2`
- `#5F5F63`

## Semantic report mapping

- `#FFFFFF` — background
- `#FFFFFF` — surface
- `#27272B` — on-surface
- `#5F5F63` — muted
- `#E5E5E5` — outline
- `#F7C600` — primary
- `#FFF4BF` — primary-container
- `#2F2F2F` — code-background
- `#F7F7F7` — code-on-background
- `#F7C600` — code-accent

## Application rules

- Use source colours as evidence, then map into semantic DESIGN.md roles.
- Adjust brightness when required for readable long-form reports and WCAG contrast.
- Long-form text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve labels and borders so grayscale PDF output remains meaningful.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
