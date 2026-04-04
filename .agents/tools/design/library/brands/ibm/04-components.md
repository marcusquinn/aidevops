<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Design: Component Stylings

> **Carbon signature:** `border-radius: 0px` on all components except Tags (24px pill). Flat design — no shadows, background-color layering for separation.

## Buttons

| Variant | Background | Text | Hover | Active |
|---------|-----------|------|-------|--------|
| Primary | `#0f62fe` Blue 60 `--cds-button-primary` | `#ffffff` | `#0353e9` `--cds-button-primary-hover` | `#002d9c` Blue 80 `--cds-button-primary-active` |
| Secondary | `#393939` Gray 80 | `#ffffff` | `#4c4c4c` Gray 70 | `#6f6f6f` Gray 60 |
| Tertiary | transparent | `#0f62fe` Blue 60, border `1px solid #0f62fe` | `#0353e9` + Blue 10 tint | — |
| Ghost | transparent | `#0f62fe` Blue 60, no border | `#e8e8e8` tint | — |
| Danger | `#da1e28` Red 60 | `#ffffff` | `#b81921` Red 70 | — |

- Padding: 14px 63px 14px 15px (asymmetric — room for trailing icon); Ghost: 14px 16px
- Height: 48px (default), 40px (compact), 64px (expressive)
- Focus: `2px solid #0f62fe` inset + `1px solid #ffffff` inner

## Cards & Containers

- Background: `#ffffff` (white) or `#f4f4f4` Gray 10 (elevated)
- Hover: background → `#e8e8e8` Gray 10 Hover
- Content padding: 16px; separation via background layering (white → gray 10 → white)

## Inputs & Forms

- Background: `#f4f4f4` Gray 10 `--cds-field`; Text: `#161616` Gray 100
- Padding: 0 16px; Height: 40px (default), 48px (large)
- Border: none sides/top; bottom `2px solid transparent` → active `2px solid #161616`
- Focus: `2px solid #0f62fe` Blue 60 `--cds-focus`; Error: `2px solid #da1e28` Red 60
- Label: 12px IBM Plex Sans, 0.32px letter-spacing, Gray 70
- Helper text: 12px Gray 60; Placeholder: `#6f6f6f` Gray 60

## Navigation

- Background: `#161616` Gray 100 (full-width dark masthead); Height: 48px
- Logo: IBM 8-bar, white on dark, left-aligned
- Links: 14px IBM Plex Sans weight 400, `#c6c6c6` Gray 30 → hover `#ffffff`
- Active link: `#ffffff` + bottom-border indicator
- Platform switcher: left-aligned horizontal tabs
- Search: icon-triggered slide-out; Mobile: hamburger + left-sliding panel

## Links

- Default: `#0f62fe` Blue 60, no underline
- Hover: `#0043ce` Blue 70 + underline; Visited: remains Blue 60
- Inline: underlined by default in body copy

## Distinctive Components

**Content Block (Hero/Feature)**
- Full-width alternating white/gray-10 bands; headline left-aligned 60px or 48px display type
- CTA: blue primary button + arrow icon; image right-aligned or below on mobile

**Tile (Clickable Card)**
- Background: `#f4f4f4` or `#ffffff`; hover: bottom-border or background-shift; no shadow
- Arrow icon bottom-right on hover

**Tag / Label**
- Background: contextual color 10% opacity (Blue 10, Red 10); text: 60-grade color
- Padding: 4px 8px; border-radius: 24px (pill); font: 12px weight 400

**Notification Banner**
- Full-width bar; Blue 60 or Gray 100 background; white text 14px; close icon right-aligned
