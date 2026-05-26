<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# consumer: Colour Palette

## Observed source colours

- `#060d17`
- `#086045`
- `#0e7455`
- `#128260`
- `#143b68`
- `#1758A6`
- `#1758a6`
- `#1F6DA2`
- `#2669ba`
- `#2976D1`
- `#2976d1`
- `#30a16b`

## Application rules

- Use observed colours as source evidence, then map them into semantic DESIGN.md roles: background, surface, on-surface, muted, outline, primary, and primary-container.
- Long-form report text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve text labels and borders so grayscale PDF output remains meaningful.
- For missing theme modes, calculate inverse roles with `colour-palette.md`; mark them as derived until previewed and contrast-checked.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
