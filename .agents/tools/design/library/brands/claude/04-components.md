<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Claude — Component Stylings

## Buttons

**Warm Sand (Secondary)**
- Background: Warm Sand (`#e8e6dc`) · Text: Charcoal Warm (`#4d4c48`)
- Padding: 0px 12px 0px 8px (asymmetric — icon-first layout)
- Radius: 8px · Shadow: `#e8e6dc 0px 0px 0px 0px, #d1cfc5 0px 0px 0px 1px`

**White Surface**
- Background: Pure White (`#ffffff`) · Text: Anthropic Near Black (`#141413`)
- Padding: 8px 16px 8px 12px · Radius: 12px
- Hover: shifts to secondary background color

**Dark Charcoal**
- Background: Dark Surface (`#30302e`) · Text: Ivory (`#faf9f5`)
- Padding: 0px 12px 0px 8px · Radius: 8px
- Shadow: `#30302e 0px 0px 0px 0px, ring 0px 0px 0px 1px`

**Brand Terracotta** — primary CTA; only chromatic button
- Background: Terracotta Brand (`#c96442`) · Text: Ivory (`#faf9f5`)
- Radius: 8–12px · Shadow: `#c96442 0px 0px 0px 0px, #c96442 0px 0px 0px 1px`

**Dark Primary**
- Background: Anthropic Near Black (`#141413`) · Text: Warm Silver (`#b0aea5`)
- Padding: 9.6px 16.8px · Radius: 12px
- Border: `1px solid #30302e` (dark theme surfaces)

## Cards & Containers

- Background: Ivory (`#faf9f5`) or Pure White (`#ffffff`) on light; Dark Surface (`#30302e`) on dark
- Border: `1px solid #f0eee6` on light; `1px solid #30302e` on dark
- Radius: 8px standard · 16px featured · 32px hero/embedded media
- Shadow: `rgba(0,0,0,0.05) 0px 4px 24px` (elevated content)
- Ring shadow: `0px 0px 0px 1px` for interactive card states
- Section borders: `1px 0px 0px` (top-only) for list item separators

## Inputs & Forms

- Text: Anthropic Near Black (`#141413`) · Padding: 1.6px 12px · Radius: 12px
- Border: standard warm borders
- Focus: Focus Blue (`#3898ec`) border-color — only cool color in system

## Navigation

- Sticky top nav with warm background
- Logo: Claude wordmark in Anthropic Near Black
- Links: Near Black (`#141413`), Olive Gray (`#5e5d59`), Dark Warm (`#3d3d3a`)
- Nav border: `1px solid #30302e` (dark) or `1px solid #f0eee6` (light)
- CTA: Terracotta Brand button or White Surface button
- Hover: text shifts to foreground-primary, no decoration

## Image Treatment

- Product screenshots of Claude chat interface; generous border-radius (16–32px)
- Embedded video players with rounded corners
- Dark UI screenshots contrast against warm light canvas
- Organic, hand-drawn illustrations for conceptual sections

## Distinctive Components

**Model Comparison Cards**
- Opus 4.5, Sonnet 4.5, Haiku 4.5 in bordered card grid
- Name, description, capability badges per card
- Border Warm (`#e8e6dc`) separation between items

**Organic Illustrations**
- Hand-drawn-feeling vector illustrations: terracotta, black, muted green
- Abstract/conceptual (not literal product diagrams)

**Dark/Light Section Alternation**
- Page alternates Parchment light and Near Black dark sections
- Each section is a distinct visual environment
