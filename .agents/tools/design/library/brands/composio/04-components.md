<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Composio — Component Stylings

## Buttons

**Primary CTA (White Fill)**
- Background: Pure White (`#ffffff`)
- Text: Near Black (`oklch(0.145 0 0)`)
- Padding: comfortable (8px 24px)
- Border: none
- Radius: subtly rounded (likely 4px based on token scale)
- Hover: likely subtle opacity reduction or slight gray shift

**Cyan Accent CTA**
- Background: Electric Cyan at 12% opacity (`rgba(0,255,255,0.12)`)
- Text: Near Black (`oklch(0.145 0 0)`)
- Padding: comfortable (8px 24px)
- Border: thin solid Ocean Blue (`1px solid rgb(0,150,255)`)
- Radius: subtly rounded (4px)
- Creates a "glowing from within" effect on dark backgrounds

**Ghost / Outline (Signal Blue)**
- Background: transparent
- Text: Near Black (`oklch(0.145 0 0)`)
- Padding: balanced (10px)
- Border: thin solid Signal Blue (`1px solid rgb(0,137,255)`)
- Hover: likely fill or border color shift

**Ghost / Outline (Charcoal)**
- Background: transparent
- Text: Near Black (`oklch(0.145 0 0)`)
- Padding: balanced (10px)
- Border: thin solid Charcoal (`1px solid rgb(44,44,44)`)
- For secondary/tertiary actions on dark surfaces

**Phantom Button**
- Background: Phantom White (`rgba(255,255,255,0.2)`)
- Text: Whisper White (`rgba(255,255,255,0.5)`)
- No visible border
- Used for deeply de-emphasized actions

## Cards & Containers

- Background: Pure Black (`#000000`) or transparent
- Border: white at very low opacity, ranging from Border Mist 04 (`rgba(255,255,255,0.04)`) to Border Mist 12 (`rgba(255,255,255,0.12)`) depending on prominence
- Radius: barely rounded corners (2px for inline elements, 4px for content cards)
- Shadow: select cards use the hard-offset brutalist shadow (`rgba(0,0,0,0.15) 4px 4px 0px 0px`) — a distinctive design choice that adds raw depth
- Elevation shadow: deeper containers use soft diffuse shadow (`rgba(0,0,0,0.5) 0px 8px 32px`)
- Hover behavior: likely subtle border opacity increase or faint glow effect

## Inputs & Forms

- No explicit input token data extracted — inputs likely follow the dark-surface pattern with:
  - Background: transparent or Pure Black
  - Border: Border Mist 10 (`rgba(255,255,255,0.10)`)
  - Focus: border shifts to Signal Blue (`#0089ff`) or Electric Cyan
  - Text: Pure White with Ghost White placeholder

## Navigation

- Sticky top nav bar on dark/black background
- Logo (white SVG): Composio wordmark on the left
- Nav links: Pure White (`#ffffff`) at standard body size (16px, abcDiatype)
- CTA button in the nav: White Fill Primary style
- Mobile: collapses to hamburger menu, single-column layout
- Subtle bottom border on nav (Border Mist 06-08)

## Image Treatment

- Dark-themed product screenshots and UI mockups dominate
- Images sit within bordered containers matching the card system
- Blue/cyan gradient glows behind or beneath feature images
- No visible border-radius on images beyond container rounding (4px)
- Full-bleed within their card containers

## Distinctive Components

**Stats/Metrics Display**
- Large monospace numbers (JetBrains Mono) — "10k+" style
- Tight layout with subtle label text beneath

**Code Blocks / Terminal Previews**
- Dark containers with JetBrains Mono
- Syntax-highlighted content
- Subtle bordered containers (Border Mist 10)

**Integration/Partner Logos Grid**
- Grid layout of tool logos on dark surface
- Contained within bordered card
- Demonstrates ecosystem breadth

**"COMPOSIO" Brand Display**
- Oversized brand typography — likely the largest text on the page
- Used as a section divider/brand statement
- Stark white on black
