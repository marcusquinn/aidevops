<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoltAgent Design System: Component Stylings

## Buttons

**Ghost / Outline (Standard)** — default interactive element
- Background: transparent
- Text: Pure White (`#ffffff`)
- Padding: 12px 16px
- Border: `1px solid #3d3a39` (Warm Charcoal)
- Radius: 6px
- Hover: background `rgba(0, 0, 0, 0.2)`, opacity 0.4
- Outline: `rgba(33, 196, 93, 0.5)`

**Primary Green CTA** — "powered on" state; green text on dark = active terminal command
- Background: Carbon Surface (`#101010`)
- Text: VoltAgent Mint (`#2fd6a1`)
- Padding: 12px 16px
- Border: none (outline-based focus indicator)
- Outline: `rgb(47, 214, 161)`
- Hover: same as Ghost

**Tertiary / Emphasized Container Button** — card-like; use for code copy blocks, feature CTAs
- Background: Carbon Surface (`#101010`)
- Text: Snow White (`#f2f2f2`)
- Padding: 20px
- Border: `3px solid #3d3a39` (Warm Charcoal)
- Radius: 8px

## Cards & Containers

- Background: Carbon Surface (`#101010`) — one shade lighter than page canvas
- Border: `1px solid #3d3a39` standard; `2px solid #00d992` highlighted/active
- Radius: 8px content cards; 4–6px inline containers
- Shadow L1: `rgba(92, 88, 85, 0.2) 0px 0px 15px` (standard elevation)
- Shadow L2: `rgba(0, 0, 0, 0.7) 0px 20px 60px` + `rgba(148, 163, 184, 0.1) 0px 0px 0px 1px inset` (hero/feature)
- Hover: border shifts toward green accent or subtle opacity increase
- Dashed variant: `1px dashed rgba(79, 93, 117, 0.4)` for workflow/diagram containers

## Inputs & Forms

Minimal form UI (landing-page focused). Inferred style: Carbon Surface background, Warm Charcoal border, VoltAgent Mint focus ring, Snow White text. The install command (`npm create voltagent-app@latest`) is a styled code block, not an input.

## Navigation

- Sticky top bar on Abyss Black canvas
- Logo: bolt icon with animated green glow (`drop-shadow` cycling 2px–8px)
- Structure: Logo → Product → Use Cases → Resources → GitHub stars badge → Docs CTA
- Link text: Snow White (`#f2f2f2`), 14–16px Inter weight 500
- Hover: green variants (`#00c182` or `#00ffaa`)
- Mobile: hamburger → single-column vertical

## Image Treatment

- Dark product screenshots and architectural diagrams; code blocks as primary visual content (SFMono-Regular)
- Agent workflow visualizations: interactive node graphs with green connection lines
- Decorative dot-pattern backgrounds behind hero sections
- Full-bleed within cards, 8px radius

## Distinctive Components

**npm Install Command Block** — primary CTA ("install first, read later")
- `npm create voltagent-app@latest` as copyable command block
- SFMono-Regular on Carbon Surface with copy-to-clipboard

**Company Logo Marquee**
- Infinite horizontal scroll (`scrollLeft`/`scrollRight`, 25–80s)
- Pauses on hover and `prefers-reduced-motion`

**Feature Section Cards**
- Left: syntax-highlighted code; Right: feature description
- Active border: `2px solid #00d992`
- Padding: 24–32px

**Agent Flow Diagrams**
- Interactive node graphs; green connection lines; nodes as Warm Charcoal mini-cards

**Community / GitHub Section**
- GitHub icon anchor; star count + contributor metrics
- Footer links: Discord, X, Reddit, LinkedIn, YouTube
