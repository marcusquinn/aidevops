<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Expo — Typography Rules

## Font Family

- **Primary**: `Inter`, with fallbacks: `-apple-system, system-ui`
- **Monospace**: `JetBrains Mono`, with fallback: `ui-monospace`
- **System Fallback**: `system-ui, Segoe UI, Roboto, Helvetica, Arial, Apple Color Emoji, Segoe UI Emoji`

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display / Hero | Inter | 64px (4rem) | 700–900 | 1.10 (tight) | -1.6px to -3px | Maximum impact, extreme tracking |
| Section Heading | Inter | 48px (3rem) | 600 | 1.10 (tight) | -2px | Feature section anchors |
| Sub-heading | Inter | 20px (1.25rem) | 600 | 1.20 (tight) | -0.25px | Card titles, feature names |
| Body Large | Inter | 18px (1.13rem) | 400–500 | 1.40 | normal | Intro paragraphs, section descriptions |
| Body / Button | Inter | 16px (1rem) | 400–700 | 1.25–1.40 | normal | Standard text, nav links, buttons |
| Caption / Label | Inter | 14px (0.88rem) | 400–600 | 1.00–1.40 | normal | Descriptions, metadata, badge text |
| Tag / Small | Inter | 12px (0.75rem) | 500 | 1.00–1.60 | normal | Smallest sans-serif text, badges |
| Code Body | JetBrains Mono | 16px (1rem) | 400–600 | 1.40 | normal | Inline code, terminal commands |
| Code Caption | JetBrains Mono | 14px (0.88rem) | 400–600 | 1.40 | normal | Code snippets, technical labels |
| Code Small | JetBrains Mono | 12px (0.75rem) | 400 | 1.60 | normal | Uppercase tech tags |

## Principles

- **One typeface, full expression**: Inter is the only sans-serif, used from weight 400 (regular) through 900 (black). This gives the design a unified voice while still achieving dramatic contrast between whisper-light body text and thundering display headlines.
- **Extreme negative tracking at scale**: Headlines at 64px use -1.6px to -3px letter-spacing, creating ultra-dense text blocks that feel like logotypes. This aggressive compression is the signature typographic move.
- **Weight as hierarchy**: 700–900 for display, 600 for headings, 500 for emphasis, 400 for body. The jumps are decisive — no ambiguous in-between weights.
- **Consistent 1.40 body line-height**: Nearly all body and UI text shares 1.40 line-height, creating a rhythmic vertical consistency.
