<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Design: Layout Principles

## Spacing System

- Base unit: 8px (Carbon 2x grid)
- Component spacing scale: 2px, 4px, 8px, 12px, 16px, 24px, 32px, 40px, 48px
- Layout spacing scale: 16px, 24px, 32px, 48px, 64px, 80px, 96px, 160px
- Mini unit: 8px (smallest usable spacing)
- Padding within components: typically 16px
- Gap between cards/tiles: 1px (hairline) or 16px (standard)

## Grid & Container

- 16-column grid (Carbon's 2x grid system)
- Max content width: 1584px (max breakpoint)
- Column gutters: 32px (16px on mobile)
- Margin: 16px (mobile), 32px (tablet+)
- Content typically spans 8-12 columns for readable line lengths
- Full-bleed sections alternate with contained content

## Whitespace Philosophy

- **Functional density**: Carbon favors productive density over expansive whitespace. Sections are tightly packed compared to consumer design systems — this reflects IBM's enterprise DNA.
- **Background-color zoning**: Instead of massive padding between sections, IBM uses alternating background colors (white → gray 10 → white) to create visual separation with minimal vertical space.
- **Consistent 48px rhythm**: Major section transitions use 48px vertical spacing. Hero sections may use 80px–96px.

## Border Radius Scale

- **0px**: Primary buttons, inputs, tiles, cards — the dominant treatment. Carbon is fundamentally rectangular.
- **2px**: Occasionally on small interactive elements (tags)
- **24px**: Tags/labels (pill shape — the sole rounded exception)
- **50%**: Avatar circles, icon containers
