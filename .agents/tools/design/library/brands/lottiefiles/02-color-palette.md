<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# lottiefiles: Colour Palette

## Browser-observed colours

- `#003681`
- `#0051c3`
- `#086fff`
- `#0a0a0a`
- `#1d1d1d`
- `#228b49`
- `#262626`
- `#2db35e`
- `#313131`
- `#450a0a`
- `#4693ff`
- `#4a4a4a`
- `#595959`
- `#780a02`
- `#82b6ff`
- `#991b1b`
- `#9d94ec`
- `#b20f03`
- `#b6b6b6`
- `#b91c1c`

## Application rules

- Use observed colours as source evidence, then map them into semantic DESIGN.md roles: background, surface, on-surface, muted, outline, primary, and primary-container.
- Long-form report text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve text labels and borders so grayscale PDF output remains meaningful.
- For missing theme modes, calculate inverse roles with `colour-palette.md`; mark them as derived until previewed and contrast-checked.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
