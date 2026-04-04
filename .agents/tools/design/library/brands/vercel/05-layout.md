<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Vercel — Layout Principles

## Spacing System

- Base unit: 8px
- Scale: 1px, 2px, 3px, 4px, 5px, 6px, 8px, 10px, 12px, 14px, 16px, 32px, 36px, 40px
- Notable gap: jumps from 16px to 32px — no 20px or 24px in primary scale

## Grid & Container

- Max content width: approximately 1200px
- Hero: centered single-column with generous top padding
- Feature sections: 2–3 column grids for cards
- Full-width dividers using `border-bottom: 1px solid #171717`
- Code/dashboard screenshots as full-width or contained with border

## Whitespace Philosophy

- **Gallery emptiness**: Massive vertical padding between sections (80px–120px+). The white space IS the design — it communicates that Vercel has nothing to prove and nothing to hide.
- **Compressed text, expanded space**: The aggressive negative letter-spacing on headlines is counterbalanced by generous surrounding whitespace. The text is dense; the space around it is vast.
- **Section rhythm**: White sections alternate with white sections — there's no color variation between sections. Separation comes from borders (shadow-borders) and spacing alone.

## Border Radius Scale

- Micro (2px): Inline code snippets, small spans
- Subtle (4px): Small containers
- Standard (6px): Buttons, links, functional elements
- Comfortable (8px): Cards, list items
- Image (12px): Featured cards, image containers (top-rounded)
- Large (64px): Tab navigation pills
- XL (100px): Large navigation links
- Full Pill (9999px): Badges, status pills, tags
- Circle (50%): Menu toggle, avatar containers
