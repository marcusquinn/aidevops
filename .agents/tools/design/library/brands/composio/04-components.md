<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Composio — Component Stylings

## Buttons

Defaults (unless overridden): Text: Near Black (`oklch(0.145 0 0)`), Radius: 4px

**Primary CTA (White Fill)**
- Background: Pure White (`#ffffff`)
- Padding: 8px 24px
- Border: none
- Hover: subtle opacity reduction or slight gray shift

**Cyan Accent CTA**
- Background: Electric Cyan at 12% opacity (`rgba(0,255,255,0.12)`)
- Padding: 8px 24px
- Border: `1px solid rgb(0,150,255)` (Ocean Blue)
- "Glowing from within" effect on dark backgrounds

**Ghost / Outline** — Background: transparent, Padding: 10px
- Signal Blue: Border `1px solid rgb(0,137,255)`; Hover: fill or border color shift
- Charcoal: Border `1px solid rgb(44,44,44)`; secondary/tertiary actions on dark surfaces

**Phantom Button**
- Background: `rgba(255,255,255,0.2)` (Phantom White)
- Text: `rgba(255,255,255,0.5)` (Whisper White)
- No border — de-emphasized actions

## Cards & Containers

- Background: `#000000` or transparent
- Border: Border Mist 04–12 (`rgba(255,255,255,0.04)` to `rgba(255,255,255,0.12)`) by prominence
- Radius: 2px inline elements, 4px content cards
- Shadow (select cards): hard-offset brutalist `rgba(0,0,0,0.15) 4px 4px 0px 0px`
- Elevation shadow: soft diffuse `rgba(0,0,0,0.5) 0px 8px 32px`
- Hover: subtle border opacity increase or faint glow

## Inputs & Forms

- Background: transparent or `#000000`
- Border: Border Mist 10 (`rgba(255,255,255,0.10)`)
- Focus: border shifts to Signal Blue (`#0089ff`) or Electric Cyan
- Text: Pure White; placeholder: Ghost White

## Navigation

- Sticky top bar on dark/black background
- Logo: white SVG Composio wordmark, left-aligned
- Nav links: `#ffffff`, 16px abcDiatype
- Nav CTA: White Fill Primary style
- Mobile: hamburger menu, single-column layout
- Bottom border: Border Mist 06–08

## Image Treatment

- Dark-themed product screenshots in bordered containers matching card system
- Blue/cyan gradient glows behind feature images
- No border-radius beyond container rounding (4px)
- Full-bleed within card containers

## Distinctive Components

**Stats/Metrics Display**
- Large JetBrains Mono numbers — "10k+" style
- Subtle label text beneath

**Code Blocks / Terminal Previews**
- Dark containers, JetBrains Mono, syntax-highlighted
- Border Mist 10 container border

**Integration/Partner Logos Grid**
- Tool logos grid on dark surface, within bordered card

**"COMPOSIO" Brand Display**
- Oversized brand typography — section divider/brand statement
- Stark white on black
