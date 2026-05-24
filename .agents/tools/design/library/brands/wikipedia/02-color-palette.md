<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# wikipedia: Colour Palette

## Browser-observed colours

- `#006400`
- `#049dff`
- `#062a50`
- `#099979`
- `#0a4b8f`
- `#0e65c0`
- `#101418`
- `#121212`
- `#132821`
- `#177860`
- `#1b223d`
- `#202122`
- `#233566`
- `#27292d`
- `#2cb491`
- `#2d2212`
- `#3056a9`
- `#353262`
- `#3c1a13`
- `#404244`

## Application rules

- Use observed colours as source evidence, then map them into semantic DESIGN.md roles: background, surface, on-surface, muted, outline, primary, and primary-container.
- Long-form report text must use high-contrast `on-surface`, not decorative accent colours.
- Badge/status colours must preserve text labels and borders so grayscale PDF output remains meaningful.
- For missing theme modes, calculate inverse roles with `colour-palette.md`; mark them as derived until previewed and contrast-checked.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
