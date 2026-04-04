<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Uber Design: Component Stylings

## Buttons

**Primary Black (CTA)**

- Background: Uber Black (`#000000`)
- Text: Pure White (`#ffffff`)
- Padding: 10px 12px
- Radius: 999px (full pill)
- Outline: none
- Focus: inset ring `rgb(255,255,255) 0px 0px 0px 2px`

**Secondary White**

- Background: Pure White (`#ffffff`)
- Text: Uber Black (`#000000`)
- Padding: 10px 12px
- Radius: 999px (full pill)
- Hover: background shifts to Hover Gray (`#e2e2e2`)
- Focus: background shifts to Hover Gray, inset ring appears

**Chip / Filter**

- Background: Chip Gray (`#efefef`)
- Text: Uber Black (`#000000`)
- Padding: 14px 16px
- Radius: 999px (full pill)
- Active: inset shadow `rgba(0,0,0,0.08)`

**Floating Action**

- Background: Pure White (`#ffffff`)
- Text: Uber Black (`#000000`)
- Padding: 14px
- Radius: 999px (full pill)
- Shadow: `rgba(0,0,0,0.16) 0px 2px 8px 0px`
- Transform: `translateY(2px)` slight offset
- Hover: background shifts to `#f3f3f3`

## Cards & Containers

- Background: Pure White (`#ffffff`); no distinct card background differentiation
- Border: none — cards defined by shadow, not stroke
- Radius: 8px standard; 12px featured/promoted
- Shadow: `rgba(0,0,0,0.12) 0px 4px 16px 0px`
- Content-dense with minimal internal padding
- Image-led cards: full-bleed imagery with text overlay or below

## Inputs & Forms

- Text: Uber Black (`#000000`)
- Background: Pure White (`#ffffff`)
- Border: 1px solid Black (`#000000`)
- Radius: 8px
- Padding: standard comfortable spacing
- Focus: standard browser focus ring

## Navigation

- Sticky top, white background
- Logo: Uber wordmark/icon at 24x24px in black
- Links: UberMoveText 14-18px, weight 500, Uber Black
- Pill-shaped nav chips: Chip Gray (`#efefef`) background ("Ride", "Drive", "Business", "Uber Eats")
- Menu toggle: circular button, 50% border-radius
- Mobile: hamburger menu

## Image Treatment

- Warm, hand-illustrated scenes for feature sections (not photographs)
- Hero sections: bold photography or illustration, full-width
- QR codes for app download CTAs
- Contained imagery: 8px or 12px border-radius

## Distinctive Components

**Category Pill Navigation**

- Horizontal row of pill-shaped buttons ("Ride", "Drive", "Business", "Uber Eats", "About")
- Each pill: Chip Gray background, black text, 999px radius
- Active: black background, white text (inversion)

**Hero with Dual Action**

- Split hero: text/CTA left, map/illustration right
- Two input fields side by side for pickup/destination
- "See prices" CTA: black pill button

**Plan-Ahead Cards**

- Cards for "Uber Reserve" and trip planning features
- Illustration-heavy, warm human-centric imagery
- Black CTA buttons with white text at bottom
