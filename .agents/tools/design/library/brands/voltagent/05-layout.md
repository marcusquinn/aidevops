<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoltAgent Design System: Layout Principles

## Spacing System

- Base unit: 8px
- Scale: 2px, 4px, 5px, 6px, 6.4px, 8px, 12px, 16px, 20px, 24px, 28px, 32px, 40px, 48px, 64px
- Button padding: 12px 16px (standard), 20px (container-button)
- Card internal padding: approximately 24–32px
- Section vertical spacing: generous (estimated 64–96px between major sections)
- Component gap: 16–24px between sibling cards/elements

## Grid & Container

- Max container width: approximately 1280–1440px, centered
- Hero: centered single-column with maximum breathing room
- Feature sections: alternating asymmetric layouts (code left / text right, then reversed)
- Logo marquee: full-width horizontal scroll, breaking the container constraint
- Card grids: 2–3 column for feature showcases
- Integration grid: responsive multi-column for partner/integration icons

## Whitespace Philosophy

- **Cinematic breathing room between sections**: Massive vertical gaps create a "scroll-through-chapters" experience — each section feels like a new scene.
- **Dense within components**: Cards and code blocks are internally compact, with tight line-heights and controlled padding. Information is concentrated, not spread thin.
- **Border-defined separation**: Rather than relying solely on whitespace, VoltAgent uses the Warm Charcoal border system (`#3d3a39`) to delineate content zones. The border IS the whitespace signal.
- **Hero-first hierarchy**: The top of the page commands the most space — the "AI Agent Engineering Platform" headline and npm command get maximum vertical runway before the first content section appears.

## Border Radius Scale

- Nearly squared (4px): Small inline elements, SVG containers, code spans — the sharpest treatment, conveying technical precision
- Subtly rounded (6px): Buttons, links, clipboard actions — the workhorse radius for interactive elements
- Code-specific (6.4px): Code blocks, `pre` elements, clipboard copy targets — a deliberate micro-distinction from standard 6px
- Comfortably rounded (8px): Content cards, feature containers, emphasized buttons — the standard containment radius
- Pill-shaped (9999px): Tags, badges, status indicators, pill-shaped navigation elements — the roundest treatment for small categorical labels
