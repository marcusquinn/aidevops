<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Uber Design: Layout Principles

## Spacing System

- Base unit: 8px
- Scale: 4px, 6px, 8px, 10px, 12px, 14px, 16px, 18px, 20px, 24px, 32px
- Button padding: 10px 12px (compact) or 14px 16px (comfortable)
- Card internal padding: approximately 24-32px
- Section vertical spacing: approximately 64-96px between major sections

## Grid & Container

- Max container width: approximately 1136px, centered
- Hero: split layout with text left, visual right
- Feature sections: 2-column card grids or full-width single-column
- Footer: multi-column link grid on black background
- Full-width sections extending to viewport edges

## Whitespace Philosophy

- **Efficient, not airy**: Uber's whitespace is functional — enough to separate, never enough to feel empty. Transit-system spacing: compact, clear, purpose-driven.
- **Content-dense cards**: Cards pack information tightly with minimal internal spacing, relying on shadow and radius to define boundaries.
- **Section breathing room**: Major sections get generous vertical spacing, but within sections, elements are closely grouped.

## Border Radius Scale

| Value | Use |
|-------|-----|
| 0px | Not used — no square corners on interactive elements |
| 8px | Content cards, input fields, listboxes |
| 12px | Featured cards, larger containers, link cards |
| 999px | All buttons, chips, navigation items, pills |
| 50% | Avatar images, icon containers, circular controls |
