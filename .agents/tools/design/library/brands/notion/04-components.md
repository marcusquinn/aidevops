<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Notion — Component Stylings

## Buttons

| Variant | Background | Text | Padding | Radius | Hover / Active |
|---------|-----------|------|---------|--------|----------------|
| Primary Blue | `#0075de` | `#ffffff` | 8px 16px | 4px | bg→`#005bab` / scale(0.9) |
| Secondary | `rgba(0,0,0,0.05)` | `#000000` | 8px 16px | 4px | color shift, scale(1.05) / scale(0.9) |
| Ghost / Link | transparent | `rgba(0,0,0,0.95)` | — | — | underline |
| Pill Badge | `#f2f9ff` | `#097fe8` | 4px 8px | 9999px | — |

- Primary: focus `2px solid` outline + `var(--shadow-level-200)` shadow. Use: CTA ("Get Notion free", "Try it")
- Secondary: Use: secondary actions, form submissions
- Ghost: Use: tertiary actions, inline links
- Pill Badge: 12px weight 600. Use: status badges, feature labels, "New" tags

## Cards & Containers

- Background: `#ffffff` · Border: `1px solid rgba(0,0,0,0.1)` (whisper) · Radius: 12px standard, 16px hero
- Shadow: `rgba(0,0,0,0.04) 0px 4px 18px, rgba(0,0,0,0.027) 0px 2.025px 7.84688px, rgba(0,0,0,0.02) 0px 0.8px 2.925px, rgba(0,0,0,0.01) 0px 0.175px 1.04062px`
- Hover: subtle shadow intensification · Image cards: 12px top radius, image fills top half

## Inputs & Forms

- Background: `#ffffff` · Text: `rgba(0,0,0,0.9)` · Border: `1px solid #dddddd` · Padding: 6px · Radius: 4px
- Focus: blue outline ring · Placeholder: `#a39e98` (warm gray)

## Navigation

- Horizontal nav on white, not sticky · Logo left-aligned (33x34px icon + wordmark)
- Links: NotionInter 15px weight 500-600, near-black · Hover: `var(--color-link-primary-text-hover)`
- CTA: blue pill button right-aligned · Mobile: hamburger collapse · Product dropdowns: multi-level menus

## Image Treatment

- Border: `1px solid rgba(0,0,0,0.1)` · Top-rounded: `12px 12px 0px 0px`
- Dashboard/workspace screenshots dominate feature sections · Warm gradient backgrounds behind hero illustrations

## Distinctive Components

**Feature Cards with Illustrations:** Large illustrative headers (The Great Wave, product UI screenshots) · 12px radius + whisper border · Title 22px/700, description 16px/400 · Alt bg: `#f6f5f4`

**Trust Bar / Logo Grid:** Company logos in brand colors · Horizontal scroll or grid with team counts · Metric display: large number + description

**Metric Cards:** Large number (e.g., "$4,200 ROI") · NotionInter 40px+ weight 700 · Description in warm gray · Whisper-bordered container
