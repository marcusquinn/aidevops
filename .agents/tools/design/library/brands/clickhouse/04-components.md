<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Component Stylings

## Buttons

| Variant | Background | Text | Padding | Radius | Border | Hover | Active | Purpose |
|---------|-----------|------|---------|--------|--------|-------|--------|---------|
| Neon Primary | `#faff69` | `#151515` | 0px 16px | 4px | `1px solid #faff69` | bg → `rgb(29,29,29)`, text stays | text → `#f4f692` | Eye-catching CTA — neon on black |
| Dark Solid | `#141414` | `#ffffff` | 12px 16px | 4px or 8px | `1px solid #141414` | bg → `#3a3a3a`, text 80% opacity | text → Pale Yellow | Standard action button |
| Forest Green | `#166534` | `#ffffff` | 12px 16px | — | `1px solid #141414` | same dark shift | Pale Yellow text | "Get Started" / primary conversion |
| Ghost / Outlined | transparent | `#ffffff` | 0px 32px | 4px | `1px solid #4f5100` (olive) | dark bg shift | Pale Yellow text | Secondary actions, neon-tinted border |
| Pill Toggle | transparent | — | — | 9999px | — | — | — | Toggle/switch elements |

## Cards & Containers

- Background: transparent or Near Black
- Border: `1px solid rgba(65, 65, 65, 0.8)` — signature charcoal containment
- Radius: 4px (small elements) or 8px (cards, containers)

| Shadow | Value |
|--------|-------|
| Level 1 — subtle | `rgba(0,0,0,0.1) 0px 1px 3px, rgba(0,0,0,0.1) 0px 1px 2px -1px` |
| Level 2 — medium | `rgba(0,0,0,0.1) 0px 10px 15px -3px, rgba(0,0,0,0.1) 0px 4px 6px -4px` |
| Level 3 — inset ("pressed") | `rgba(0,0,0,0.06) 0px 4px 4px, rgba(0,0,0,0.14) 0px 4px 25px inset` |

- Neon-highlighted cards: selected/active cards get neon yellow-green border or accent

## Navigation

- Dark nav on black background
- Logo: ClickHouse wordmark + icon in yellow/neon
- Links: white text, hover to Neon Volt (`#faff69`)
- CTA: Neon Volt button or Forest Green button
- Uppercase labels for categories

## Distinctive Components

### Performance Stats
- Oversized numbers (72px+, weight 700–900)
- Brief descriptions beneath
- High-contrast neon accents on key metrics
- Primary visual proof of performance claims

### Neon-Highlighted Card
- Standard dark card with neon yellow-green border highlight — "selected" or "featured" treatment

### Code Blocks
- Dark surface with Inconsolata at weight 600
- Neon and white syntax highlighting
- Terminal-like aesthetic

### Trust Bar
- Company logos on dark background
- Monochrome/white logo treatment
- Horizontal layout
