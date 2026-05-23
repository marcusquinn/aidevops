<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# indexsy: Typography

## Observed source font evidence

- `-apple-system,system-ui,BlinkMacSystemFont,`
- `Instrument Serif`
- `Inter`
- `inherit`
- `sans-serif`
- `var(--gp-font--body)`
- `var(--gp-font--headings)`

## Substitute policy

Use Inter/system sans for report headings and body so the rendered examples match the site screenshots more closely. Instrument Serif appears as a decorative source accent; use it only for bespoke italic words or logo-like moments outside the generic Markdown renderer.

## Report typography requirements

- Screen body text: 16px or larger with 1.6-1.75 line height and generous paragraph spacing.
- PDF body text: 10.5-12pt equivalent.
- Headings: oversized, white, low-to-medium weight, tight tracking, and short line lengths.
- Code/data: use a readable monospace stack and wrap long lines in PDF.
