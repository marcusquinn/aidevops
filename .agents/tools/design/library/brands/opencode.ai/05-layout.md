<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: OpenCode — Layout Principles

## Spacing System

- Base unit: 8px
- Fine scale: 1px, 2px, 4px (sub-8px for borders and micro-adjustments)
- Standard scale: 8px, 12px, 16px, 20px, 24px
- Extended scale: 32px, 40px, 48px, 64px, 80px, 96px
- The system follows a clean 4/8px grid with consistent doubling

## Grid & Container

- Max content width: approximately 800-900px (narrow, reading-optimized)
- Single-column layout as the primary pattern
- Centered content with generous horizontal margins
- Hero section: full-width dark terminal element
- Feature sections: single-column text blocks
- Footer: multi-column link grid

## Whitespace Philosophy

- **Monospace rhythm**: The fixed-width nature of Berkeley Mono creates a natural vertical grid. Line-heights of 1.50 and 2.00 maintain consistent rhythm.
- **Narrow and focused**: Content is constrained to a narrow column, creating generous side margins that focus attention on the text.
- **Sections through spacing**: No decorative dividers. Sections are separated by generous vertical spacing (48-96px) rather than borders or background changes.

## Border Radius Scale

- Micro (4px): Default for all elements -- buttons, containers, badges
- Input (6px): Form inputs get slightly more roundness
- The entire system uses just two radius values, reinforcing the utilitarian aesthetic
