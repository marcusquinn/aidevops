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

| Variant | Background | Border | Radius | Padding | Notes |
|---------|-----------|--------|--------|---------|-------|
| Dark Content | `#212121` | 1px solid `#353535` or `#212121` | 6px | 24px | White `#ffffff` titles, Silver `#b9b9b9` body; hover: subtle border shift or elevation |
| Feature (Full-bleed) | `#0b0b0b` or full-bleed image/gradient | none or 1px solid `#212121` | 12px | 32–48px | Large imagery with overlaid text |

## Inputs

| Variant | Background | Text | Border | Padding | Radius | Notes |
|---------|-----------|------|--------|---------|--------|-------|
| Text / Textarea | `#0b0b0b` | `#b9b9b9` | 1px solid `#212121` | 8px 12px | 3px | Focus: 2px solid `var(--focus-ring-color)` (blue); focus bg: deep cyan `#072227` |
| Search | `#0b0b0b` | `#b9b9b9` | — | 0px 12px | 3px | Placeholder: `#797979` |

## Navigation

| Component | Background | Links | Notes |
|-----------|-----------|-------|-------|
| Top Nav | `#0b0b0b` + backdrop blur | waldenburgNormal 16px, `#b9b9b9`; hover: Electric Blue via `--color-fg-accent-blue` | Logo: left-aligned wordmark<br>CTA: Sanity Red pill right-aligned<br>Separator: 1px border-bottom `#212121` |
| Footer | `#0b0b0b` | `#b9b9b9`, hover to blue | Multi-column layout<br>Section headers: White `#ffffff`, 13px uppercase IBM Plex Mono |

## Badges / Pills

Border Radius: 99999px · Padding: 8px · Font: 13px

| Variant | Background | Text |
|---------|-----------|------|
| Neutral Subtle | White `#ffffff` | Near Black `#0b0b0b` |
| Neutral Filled | Near Black `#0b0b0b` | White `#ffffff` |
