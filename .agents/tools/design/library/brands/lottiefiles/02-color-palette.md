<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# lottiefiles: Colour Palette

## Saved-page observed colours and tokens

- `--action-primary: #019d91`
- `--action-primary-hover: #00c1a2`
- `--action-focus: #00ddb3`
- `--accent-primary: #019d91`
- `--accent-secondary: #00c1a2`
- `--accent-tertiary: #00ddb3`
- `--background: oklch(100% 0 0)` for light mode
- `--foreground: oklch(14.1% .005 285.823)` for light mode
- `--background: oklch(14.1% .005 285.823)` for dark mode
- `--foreground: oklch(98.5% 0 0)` for dark mode
- `#18181B` primary dark text on light surfaces
- `#4C5863` secondary text / track colour
- `#E4EAED`, `#F0F4F7` borders and pale dividers
- `#080A0C`, `#161A1C`, `#1E2428`, `#222A30` dark-mode surfaces and borders
- `#BFC8D1`, `#AEBBC5` dark-mode secondary text

## Application rules

- Map the teal action system into `primary`, `primary-container`, focus, and interactive states.
- Long-form report text must use high-contrast `on-surface` (`#18181B` light, `#FFFFFF` dark), not teal accent colours.
- Badge/status colours must preserve text labels and borders so grayscale PDF output remains meaningful.
- Use observed dark tokens before deriving inverse roles. Derive only missing semantic aliases with `colour-palette.md`; mark them as calculated until previewed and contrast-checked.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings and non-text UI indicators: 3:1 minimum.
- Focus rings, table borders, and evidence badge borders: visible against adjacent surfaces.
