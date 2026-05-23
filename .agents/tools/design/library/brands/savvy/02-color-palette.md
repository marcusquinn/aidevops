<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# savvy: Colour Palette

## Observed source colours

- `#000000`
- `#004e3b`
- `#00776e`
- `#007956`
- `#008138`
- `#0084cc`
- `#009767`
- `#00a5ef`
- `#00baa7`
- `#00bb7f`
- `#00c758`
- `#00d2ef`

## Application rules

- Use observed colours as source evidence, then map them into semantic DESIGN.md roles: background, surface, on-surface, muted, outline, primary, and primary-container.
- Long-form report text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve text labels and borders so grayscale PDF output remains meaningful.
- For missing theme modes, calculate inverse roles with `colour-palette.md`; mark them as derived until previewed and contrast-checked.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
