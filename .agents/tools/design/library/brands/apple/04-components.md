<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Apple — Component Stylings

## Buttons

**Primary Blue (CTA)**
- Background: `#0071e3` (Apple Blue)
- Text: `#ffffff`
- Padding: 8px 15px
- Radius: 8px
- Border: 1px solid transparent
- Font: SF Pro Text, 17px, weight 400
- Hover: background brightens slightly
- Active: `#ededf2` background shift
- Focus: `2px solid var(--sk-focus-color, #0071E3)` outline
- Use: Primary call-to-action ("Buy", "Shop iPhone")

**Primary Dark**
- Background: `#1d1d1f`
- Text: `#ffffff`
- Padding: 8px 15px
- Radius: 8px
- Font: SF Pro Text, 17px, weight 400
- Use: Secondary CTA, dark variant

**Pill Link (Learn More / Shop)**
- Background: transparent
- Text: `#0066cc` (light bg) or `#2997ff` (dark bg)
- Radius: 980px (full pill)
- Border: 1px solid `#0066cc`
- Font: SF Pro Text, 14px-17px
- Hover: underline decoration
- Use: "Learn more" and "Shop" links — the signature Apple inline CTA

**Filter / Search Button**
- Background: `#fafafc`
- Text: `rgba(0, 0, 0, 0.8)`
- Padding: 0px 14px
- Radius: 11px
- Border: 3px solid `rgba(0, 0, 0, 0.04)`
- Focus: `2px solid var(--sk-focus-color, #0071E3)` outline
- Use: Search bars, filter controls

**Media Control**
- Background: `rgba(210, 210, 215, 0.64)`
- Text: `rgba(0, 0, 0, 0.48)`
- Radius: 50% (circular)
- Active: scale(0.9), background shifts
- Focus: `2px solid var(--sk-focus-color, #0071e3)` outline, white bg, black text
- Use: Play/pause, carousel arrows

## Cards & Containers

- Background: `#f5f5f7` (light) or `#272729`-`#2a2a2d` (dark)
- Border: none (borders are rare in Apple's system)
- Radius: 5px-8px
- Shadow: `rgba(0, 0, 0, 0.22) 3px 5px 30px 0px` for elevated product cards
- Content: centered, generous padding
- Hover: no standard hover state — cards are static, links within them are interactive

## Navigation

- Background: `rgba(0, 0, 0, 0.8)` (translucent dark) with `backdrop-filter: saturate(180%) blur(20px)`
- Height: 48px (compact)
- Text: `#ffffff` at 12px, weight 400
- Active: underline on hover
- Logo: Apple logomark (SVG) centered or left-aligned, 17x48px viewport
- Mobile: collapses to hamburger with full-screen overlay menu
- The nav floats above content, maintaining its dark translucent glass regardless of section background

## Image Treatment

- Products on solid-color fields (black or white) — no backgrounds, no context, just the object
- Full-bleed section images that span the entire viewport width
- Product photography at extremely high resolution with subtle shadows
- Lifestyle images confined to rounded-corner containers (12px+ radius)

## Distinctive Components

**Product Hero Module**
- Full-viewport-width section with solid background (black or `#f5f5f7`)
- Product name as the primary headline (SF Pro Display, 56px, weight 600)
- One-line descriptor below in lighter weight
- Two pill CTAs side by side: "Learn more" (outline) and "Buy" / "Shop" (filled)

**Product Grid Tile**
- Square or near-square card on contrasting background
- Product image dominating 60-70% of the tile
- Product name + one-line description below
- "Learn more" and "Shop" link pair at bottom

**Feature Comparison Strip**
- Horizontal scroll of product variants
- Each variant as a vertical card with image, name, and key specs
- Minimal chrome — the products speak for themselves
