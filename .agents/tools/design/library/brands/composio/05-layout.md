# Design System: Composio — Layout Principles

## Spacing System

- Base unit: 8px
- Scale: 1px, 2px, 4px, 6px, 8px, 10px, 12px, 14px, 16px, 18px, 20px, 24px, 30px, 32px, 40px
- Component padding: typically 10px (buttons) to 24px (CTA buttons horizontal)
- Section padding: generous vertical spacing (estimated 80-120px between major sections)
- Card internal padding: approximately 24-32px

## Grid & Container

- Max container width: approximately 1200px, centered
- Content sections use single-column or 2-3 column grids for feature cards
- Hero: centered single-column with maximum impact
- Feature sections: asymmetric layouts mixing text blocks with product screenshots

## Whitespace Philosophy

- **Breathing room between sections**: Large vertical gaps create distinct "chapters" in the page scroll.
- **Dense within components**: Cards and text blocks are internally compact (tight line-heights, minimal internal padding), creating focused information nodes.
- **Contrast-driven separation**: Rather than relying solely on whitespace, Composio uses border opacity differences and subtle background shifts to delineate content zones.

## Border Radius Scale

- Nearly squared (2px): Inline code spans, small tags, pre blocks — the sharpest treatment, conveying technical precision
- Subtly rounded (4px): Content cards, images, standard containers — the workhorse radius
- Pill-shaped (37px): Select buttons and badges — creates a softer, more approachable feel for key CTAs
- Full round (9999px+): Circular elements, avatar-like containers, decorative dots
