<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Layout Principles

## Spacing System

- Base unit: 8px
- Scale: 1px, 2px, 4px, 6px, 8px, 10px, 11px, 12px, 14px, 16px, 18px, 20px
- Notable: The scale is dense at the small end (every 2px from 4-12), reflecting Stripe's precision-oriented UI for financial data

## Grid & Container

- Max content width: approximately 1080px
- Hero: centered single-column with generous padding, lightweight headlines
- Feature sections: 2-3 column grids for feature cards
- Full-width dark sections with `#1c1e54` background for brand immersion
- Code/dashboard previews as contained cards with blue-tinted shadows

## Whitespace Philosophy

- **Precision spacing**: Unlike the vast emptiness of minimalist systems, Stripe uses measured, purposeful whitespace. Every gap is a deliberate typographic choice.
- **Dense data, generous chrome**: Financial data displays (tables, charts) are tightly packed, but the UI chrome around them is generously spaced. This creates a sense of controlled density -- like a well-organized spreadsheet in a beautiful frame.
- **Section rhythm**: White sections alternate with dark brand sections (`#1c1e54`), creating a dramatic light/dark cadence that prevents monotony without introducing arbitrary color.

## Border Radius Scale

- Micro (1px): Fine-grained elements, subtle rounding
- Standard (4px): Buttons, inputs, badges, cards -- the workhorse
- Comfortable (5px): Standard card containers
- Relaxed (6px): Navigation, larger interactive elements
- Large (8px): Featured cards, hero elements
- Compound: `0px 0px 6px 6px` for bottom-rounded containers (tab panels, dropdown footers)
