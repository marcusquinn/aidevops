<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Polymarket Times: Colour Palette

## Observed source colours

- `#F4F1EA` — cream newsprint background from fetched HTML/CSS
- `#1A1A1A` — primary ink from fetched HTML/CSS
- `#000000` — ticker/nav bars and heavy rules from fetched HTML/CSS and screenshot
- `#FFFFFF` — reverse text and panel contrast from fetched HTML/CSS
- `#008138` — market green observed in prior source evidence and screenshot direction
- `#05DF72` — bright ticker green observed in prior source evidence and screenshot direction
- red/down-market accent — screenshot shows red price/down indicators; use only for negative market states

## Semantic mapping

- `background`: `#F4F1EA`
- `surface`: `#FFFDF8`
- `on-surface`: `#1A1A1A`
- `muted`: `#374151`
- `outline`: `#000000`
- `primary`: `#008138`
- `primary-container`: `#E9E3D7`
- `code-background`: `#0A0A0A`
- `code-accent`: `#05DF72`

## Application rules

- Use black for structure: masthead rules, table borders, section dividers, and PDF-safe separators.
- Use green for positive market movement, links, and selected accents; never for long-form paragraphs.
- Use red only for negative/down-market status values and pair it with text labels.
- Keep body text high contrast on cream/surface backgrounds.
- Preserve badge labels and table borders so grayscale PDF output remains meaningful.

## Required contrast checks

- Body text on background and surface: WCAG AA 4.5:1 minimum.
- Large headings, market indicators, and non-text UI: 3:1 minimum.
- Focus rings, table borders, source links, and evidence badge borders: visible against adjacent surfaces.
