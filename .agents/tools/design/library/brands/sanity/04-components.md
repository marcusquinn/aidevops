<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Sanity — Component Stylings

## Buttons

All pill buttons: `border-radius: 99999px`. Hover state (all): Electric Blue (`#0052ef`) background, white text.

| Variant | Background | Text | Padding | Border | Font |
|---------|-----------|------|---------|--------|------|
| Primary CTA (Pill) | Sanity Red `#f36458` | White `#ffffff` | 8px 16px | none | 16px waldenburgNormal 400 |
| Secondary (Dark Pill) | Near Black `#0b0b0b` | Silver `#b9b9b9` | 8px 12px | none | — |
| Outlined (Light Pill) | White `#ffffff` | Near Black `#0b0b0b` | 8px | 1px solid `#0b0b0b` | — |
| Ghost / Subtle | Dark Gray `#212121` | Silver `#b9b9b9` | 0px 12px | 1px solid `#212121` | border-radius: 5px |
| Uppercase Label | transparent or `#212121` | Silver `#b9b9b9` | — | — | 11px waldenburgNormal 600, uppercase; used for tabs/filters |

## Cards

**Dark Content Card**
- Background: `#212121` · Border: 1px solid `#353535` or `#212121` · Border Radius: 6px · Padding: 24px
- Text: White `#ffffff` titles, Silver `#b9b9b9` body · Hover: subtle border shift or elevation

**Feature Card (Full-bleed)**
- Background: `#0b0b0b` or full-bleed image/gradient · Border: none or 1px solid `#212121` · Border Radius: 12px · Padding: 32–48px
- Contains large imagery with overlaid text

## Inputs

**Text Input / Textarea**
- Background: `#0b0b0b` · Text: `#b9b9b9` · Border: 1px solid `#212121` · Padding: 8px 12px · Border Radius: 3px
- Focus: 2px solid `var(--focus-ring-color)` (blue) · Focus background: deep cyan `#072227`

**Search Input**
- Background: `#0b0b0b` · Text: `#b9b9b9` · Padding: 0px 12px · Border Radius: 3px · Placeholder: `#797979`

## Navigation

**Top Navigation**
- Background: `#0b0b0b` with backdrop blur · Logo: left-aligned Sanity wordmark · CTA: Sanity Red pill button right-aligned
- Links: waldenburgNormal 16px, `#b9b9b9` · Link Hover: Electric Blue via `--color-fg-accent-blue` · Separator: 1px border-bottom `#212121`

**Footer**
- Background: `#0b0b0b` · Multi-column link layout
- Links: `#b9b9b9`, hover to blue · Section headers: White `#ffffff`, 13px uppercase IBM Plex Mono

## Badges / Pills

Border Radius: 99999px · Padding: 8px · Font: 13px

| Variant | Background | Text |
|---------|-----------|------|
| Neutral Subtle | White `#ffffff` | Near Black `#0b0b0b` |
| Neutral Filled | Near Black `#0b0b0b` | White `#ffffff` |
