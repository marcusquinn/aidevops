<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoltAgent Design System: Component Stylings

## Buttons

**Ghost / Outline (Standard)**
- Background: transparent
- Text: Pure White (`#ffffff`)
- Padding: comfortable (12px 16px)
- Border: thin solid Warm Charcoal (`1px solid #3d3a39`)
- Radius: comfortably rounded (6px)
- Hover: background darkens to `rgba(0, 0, 0, 0.2)`, opacity drops to 0.4
- Outline: subtle green tint (`rgba(33, 196, 93, 0.5)`)
- The default interactive element — unassuming but clearly clickable

**Primary Green CTA**
- Background: Carbon Surface (`#101010`)
- Text: VoltAgent Mint (`#2fd6a1`)
- Padding: comfortable (12px 16px)
- Border: none visible (outline-based focus indicator)
- Outline: VoltAgent Mint (`rgb(47, 214, 161)`)
- Hover: same darkening behavior as Ghost
- The "powered on" button — green text on dark surface reads as an active terminal command

**Tertiary / Emphasized Container Button**
- Background: Carbon Surface (`#101010`)
- Text: Snow White (`#f2f2f2`)
- Padding: generous (20px all sides)
- Border: thick solid Warm Charcoal (`3px solid #3d3a39`)
- Radius: comfortably rounded (8px)
- A card-like button treatment for larger interactive surfaces (code copy blocks, feature CTAs)

## Cards & Containers

- Background: Carbon Surface (`#101010`) — one shade lighter than the page canvas
- Border: `1px solid #3d3a39` (Warm Charcoal) for standard containment; `2px solid #00d992` for highlighted/active cards
- Radius: comfortably rounded (8px) for content cards; subtly rounded (4–6px) for smaller inline containers
- Shadow Level 1: Warm Ambient Haze (`rgba(92, 88, 85, 0.2) 0px 0px 15px`) for standard elevation
- Shadow Level 2: Deep Dramatic (`rgba(0, 0, 0, 0.7) 0px 20px 60px` + `rgba(148, 163, 184, 0.1) 0px 0px 0px 1px inset`) for hero/feature showcase cards
- Hover behavior: likely border color shift toward green accent or subtle opacity increase
- Dashed variant: `1px dashed rgba(79, 93, 117, 0.4)` for workflow/diagram containers — visually distinct from solid-border content cards

## Inputs & Forms

- No explicit input token data extracted — the site is landing-page focused with minimal form UI
- The npm install command (`npm create voltagent-app@latest`) is presented as a code block rather than an input field
- Inferred style: Carbon Surface background, Warm Charcoal border, VoltAgent Mint focus ring, Snow White text

## Navigation

- Sticky top nav bar on Abyss Black canvas
- Logo: VoltAgent bolt icon with animated green glow (`drop-shadow` cycling 2px–8px)
- Nav structure: Logo → Product dropdown → Use Cases dropdown → Resources dropdown → GitHub stars badge → Docs CTA
- Link text: Snow White (`#f2f2f2`) at 14–16px Inter, weight 500
- Hover: links transition to green variants (`#00c182` or `#00ffaa`)
- GitHub badge: social proof element integrated directly into nav
- Mobile: collapses to hamburger menu, single-column vertical layout

## Image Treatment

- Dark-themed product screenshots and architectural diagrams dominate
- Code blocks are treated as primary visual content — syntax-highlighted with SFMono-Regular
- Agent workflow visualizations appear as interactive node graphs with green connection lines
- Decorative dot-pattern backgrounds appear behind hero sections
- Full-bleed within card containers, respecting 8px radius rounding

## Distinctive Components

**npm Install Command Block**
- A prominent code snippet (`npm create voltagent-app@latest`) styled as a copyable command
- SFMono-Regular on Carbon Surface with a copy-to-clipboard button
- Functions as the primary CTA — "install first, read later" developer psychology

**Company Logo Marquee**
- Horizontal scrolling strip of developer/company logos
- Infinite animation (`scrollLeft`/`scrollRight`, 25–80s durations)
- Pauses on hover and for users with reduced-motion preferences
- Demonstrates ecosystem adoption without cluttering the layout

**Feature Section Cards**
- Large cards combining code examples with descriptive text
- Left: code snippet with syntax highlighting; Right: feature description
- Green accent border (`2px solid #00d992`) on highlighted/active features
- Internal padding: generous (24–32px estimated)

**Agent Flow Diagrams**
- Interactive node-graph visualizations showing agent coordination
- Connection lines use VoltAgent green variants
- Nodes styled as mini-cards within the Warm Charcoal border system

**Community / GitHub Section**
- Large GitHub icon as the visual anchor
- Star count and contributor metrics prominently displayed
- Warm social proof: Discord, X, Reddit, LinkedIn, YouTube links in footer
