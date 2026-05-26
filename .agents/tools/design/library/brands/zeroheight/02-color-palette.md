<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# zeroheight: Colour Palette

## Observed source colours

- `#000000`
- `#000001`
- `#00CA4E`
- `#00CBA0`
- `#00ca4e`
- `#00cba0`
- `#050505`
- `#0A0A0A`
- `#0a0a0a`
- `#151316`
- `#1A1A1A`
- `#1C1C1C`

## Application rules

- Use observed colours as source evidence, then map them into semantic DESIGN.md roles: background, surface, on-surface, muted, outline, primary, and primary-container.
- Long-form report text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve text labels and borders so grayscale PDF output remains meaningful.
- For missing theme modes, calculate inverse roles with `colour-palette.md`; mark them as derived until previewed and contrast-checked.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
