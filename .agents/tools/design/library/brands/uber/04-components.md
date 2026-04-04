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
- The primary action button — bold, high-contrast, unmissable

**Secondary White**

- Background: Pure White (`#ffffff`)
- Text: Uber Black (`#000000`)
- Padding: 10px 12px
- Radius: 999px (full pill)
- Hover: background shifts to Hover Gray (`#e2e2e2`)
- Focus: background shifts to Hover Gray, inset ring appears
- Used on dark surfaces or as a secondary action alongside Primary Black

**Chip / Filter**

- Background: Chip Gray (`#efefef`)
- Text: Uber Black (`#000000`)
- Padding: 14px 16px
- Radius: 999px (full pill)
- Active: inset shadow `rgba(0,0,0,0.08)`
- Navigation chips, category selectors, filter toggles

**Floating Action**

- Background: Pure White (`#ffffff`)
- Text: Uber Black (`#000000`)
- Padding: 14px
- Radius: 999px (full pill)
- Shadow: `rgba(0,0,0,0.16) 0px 2px 8px 0px`
- Transform: `translateY(2px)` slight offset
- Hover: background shifts to `#f3f3f3`
- Map controls, scroll-to-top, floating CTAs

## Cards & Containers

- Background: Pure White (`#ffffff`) on white pages; no distinct card background differentiation
- Border: none by default — cards are defined by shadow, not stroke
- Radius: 8px for standard content cards; 12px for featured/promoted cards
- Shadow: `rgba(0,0,0,0.12) 0px 4px 16px 0px` for standard lift
- Cards are content-dense with minimal internal padding
- Image-led cards use full-bleed imagery with text overlay or below

## Inputs & Forms

- Text: Uber Black (`#000000`)
- Background: Pure White (`#ffffff`)
- Border: 1px solid Black (`#000000`) — the only place visible borders appear prominently
- Radius: 8px
- Padding: standard comfortable spacing
- Focus: no extracted custom focus state — relies on standard browser focus ring

## Navigation

- Sticky top navigation with white background
- Logo: Uber wordmark/icon at 24x24px in black
- Links: UberMoveText at 14-18px, weight 500, in Uber Black
- Pill-shaped nav chips with Chip Gray (`#efefef`) background for category navigation ("Ride", "Drive", "Business", "Uber Eats")
- Menu toggle: circular button with 50% border-radius
- Mobile: hamburger menu pattern

## Image Treatment

- Warm, hand-illustrated scenes (not photographs for feature sections)
- Illustration style: slightly stylized people, warm color palette within illustrations, contemporary vibe
- Hero sections use bold photography or illustration as full-width backgrounds
- QR codes for app download CTAs
- All imagery uses standard 8px or 12px border-radius when contained in cards

## Distinctive Components

**Category Pill Navigation**

- Horizontal row of pill-shaped buttons for top-level navigation ("Ride", "Drive", "Business", "Uber Eats", "About")
- Each pill: Chip Gray background, black text, 999px radius
- Active state indicated by black background with white text (inversion)

**Hero with Dual Action**

- Split hero: text/CTA on left, map/illustration on right
- Two input fields side by side for pickup/destination
- "See prices" CTA button in black pill

**Plan-Ahead Cards**

- Cards promoting features like "Uber Reserve" and trip planning
- Illustration-heavy with warm, human-centric imagery
- Black CTA buttons with white text at bottom
