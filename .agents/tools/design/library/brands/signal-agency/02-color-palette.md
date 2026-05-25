<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency — Colour Palette

## Core tokens

| Role | Token | Value | Use |
|------|-------|-------|-----|
| Paper | `background` | `#ECEEEB` | Page background, default report paper |
| Paper alt | `paper-alt` | `#E2E5E1` | Subtle strips, neutral pills, code chips |
| Paper raised | `paper-raised` | `#F5F6F4` | Card footers, quiet panels, print-friendly raised surfaces |
| Surface | `surface` | `#FFFFFF` | Cards only when stronger contrast is required |
| Ink | `on-surface` | `#0B0D0A` | Body, headings, primary rules |
| Ink soft | `muted` | `#5A605C` | Metadata, captions, labels |
| Rule strong | `outline` | `#0B0D0A` | Section rules, component borders |
| Rule soft | `outline-soft` | `#C9CDC9` | Dividers and dotted rules |
| Rule hair | `outline-hair` | `#D9DCD8` | Internal table/cell rules |
| Signal | `primary` | `#B93A19` | Decisions, P0, cover emphasis, attention dots |
| Signal wash | `primary-container` | `#F3DED5` | Critical callout background |

## Semantic states

| State | Solid | Wash | Evidence use | Priority use |
|-------|-------|------|--------------|--------------|
| Positive | `#23784C` | `#E8F4EC` | Verified | Done/preserve |
| Negative | `#B83A22` | `#F7E6E0` | Missing | P0/critical |
| Warning | `#78621B` | `#F3ECD6` | Partial | P1/watch |
| Info | `#3068A3` | `#E5EEF8` | Inferred | P2/method note |
| Neutral | `#5A605C` | `#E2E5E1` | Backlog/no change | P3 |

## Usage rules

- One accent only. If a second decorative colour seems needed, use a state tag instead.
- State colour reads as a dot, pill, tag, wash, square, or glyph — never as paragraph text.
- Full-saturation state hues belong in compact surfaces: card headers, left bars, LEDs, tiny glyphs.
- Body paragraphs remain ink; metadata remains muted ink.
- Print exports should preserve paper warmth but may flatten dotted grids and sticky chrome.
