<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Design: Component Stylings

## Buttons

**Primary Button (Blue)**
- Background: `#0f62fe` (Blue 60) → `--cds-button-primary`
- Text: `#ffffff` (White)
- Padding: 14px 63px 14px 15px (asymmetric — room for trailing icon)
- Border: 1px solid transparent
- Border-radius: 0px (sharp rectangle — the Carbon signature)
- Height: 48px (default), 40px (compact), 64px (expressive)
- Hover: `#0353e9` (Blue 60 Hover) → `--cds-button-primary-hover`
- Active: `#002d9c` (Blue 80) → `--cds-button-primary-active`
- Focus: `2px solid #0f62fe` inset + `1px solid #ffffff` inner

**Secondary Button (Gray)**
- Background: `#393939` (Gray 80)
- Text: `#ffffff`
- Hover: `#4c4c4c` (Gray 70)
- Active: `#6f6f6f` (Gray 60)
- Same padding/radius as primary

**Tertiary Button (Ghost Blue)**
- Background: transparent
- Text: `#0f62fe` (Blue 60)
- Border: 1px solid `#0f62fe`
- Hover: `#0353e9` text + Blue 10 background tint
- Border-radius: 0px

**Ghost Button**
- Background: transparent
- Text: `#0f62fe` (Blue 60)
- Padding: 14px 16px
- Border: none
- Hover: `#e8e8e8` background tint

**Danger Button**
- Background: `#da1e28` (Red 60)
- Text: `#ffffff`
- Hover: `#b81921` (Red 70)

## Cards & Containers

- Background: `#ffffff` on white theme, `#f4f4f4` (Gray 10) for elevated cards
- Border: none (flat design — no border or shadow on most cards)
- Border-radius: 0px (matching the rectangular button aesthetic)
- Hover: background shifts to `#e8e8e8` (Gray 10 Hover) for clickable cards
- Content padding: 16px
- Separation: background-color layering (white → gray 10 → white) rather than shadows

## Inputs & Forms

- Background: `#f4f4f4` (Gray 10) — `--cds-field`
- Text: `#161616` (Gray 100)
- Padding: 0px 16px (horizontal only)
- Height: 40px (default), 48px (large)
- Border: none on sides/top — `2px solid transparent` bottom
- Bottom-border active: `2px solid #161616` (Gray 100)
- Focus: `2px solid #0f62fe` (Blue 60) bottom-border — `--cds-focus`
- Error: `2px solid #da1e28` (Red 60) bottom-border
- Label: 12px IBM Plex Sans, 0.32px letter-spacing, Gray 70
- Helper text: 12px, Gray 60
- Placeholder: Gray 60 (`#6f6f6f`)
- Border-radius: 0px (top) — inputs are sharp-cornered

## Navigation

- Background: `#161616` (Gray 100) — full-width dark masthead
- Height: 48px
- Logo: IBM 8-bar logo, white on dark, left-aligned
- Links: 14px IBM Plex Sans, weight 400, `#c6c6c6` (Gray 30) default
- Link hover: `#ffffff` text
- Active link: `#ffffff` with bottom-border indicator
- Platform switcher: left-aligned horizontal tabs
- Search: icon-triggered slide-out search field
- Mobile: hamburger with left-sliding panel

## Links

- Default: `#0f62fe` (Blue 60) with no underline
- Hover: `#0043ce` (Blue 70) with underline
- Visited: remains Blue 60 (no visited state change)
- Inline links: underlined by default in body copy

## Distinctive Components

**Content Block (Hero/Feature)**
- Full-width alternating white/gray-10 background bands
- Headline left-aligned with 60px or 48px display type
- CTA as blue primary button with arrow icon
- Image/illustration right-aligned or below on mobile

**Tile (Clickable Card)**
- Background: `#f4f4f4` or `#ffffff`
- Full-width bottom-border or background-shift hover
- Arrow icon bottom-right on hover
- No shadow — flatness is the identity

**Tag / Label**
- Background: contextual color at 10% opacity (e.g., Blue 10, Red 10)
- Text: corresponding 60-grade color
- Padding: 4px 8px
- Border-radius: 24px (pill — exception to the 0px rule)
- Font: 12px weight 400

**Notification Banner**
- Full-width bar, typically Blue 60 or Gray 100 background
- White text, 14px
- Close/dismiss icon right-aligned
