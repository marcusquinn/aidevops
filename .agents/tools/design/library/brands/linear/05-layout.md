<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Linear — Layout Principles

## Spacing System

- Base unit: 8px
- Scale: 1px, 4px, 7px, 8px, 11px, 12px, 16px, 19px, 20px, 22px, 24px, 28px, 32px, 35px
- The 7px and 11px values suggest micro-adjustments for optical alignment
- Primary rhythm: 8px, 16px, 24px, 32px (standard 8px grid)

## Grid & Container

- Max content width: approximately 1200px
- Hero: centered single-column with generous vertical padding
- Feature sections: 2–3 column grids for feature cards
- Full-width dark sections with internal max-width constraints
- Changelog: single-column timeline layout

## Whitespace Philosophy

- **Darkness as space**: On Linear's dark canvas, empty space isn't white — it's absence. The near-black background IS the whitespace, and content emerges from it.
- **Compressed headlines, expanded surroundings**: Display text at 72px with -1.584px tracking is dense and compressed, but sits within vast dark padding. The contrast between typographic density and spatial generosity creates tension.
- **Section isolation**: Each feature section is separated by generous vertical padding (80px+) with no visible dividers — the dark background provides natural separation.

## Border Radius Scale

- Micro (2px): Inline badges, toolbar buttons, subtle tags
- Standard (4px): Small containers, list items
- Comfortable (6px): Buttons, inputs, functional elements
- Card (8px): Cards, dropdowns, popovers
- Panel (12px): Panels, featured cards, section containers
- Large (22px): Large panel elements
- Full Pill (9999px): Chips, filter pills, status tags
- Circle (50%): Icon buttons, avatars, status dots
