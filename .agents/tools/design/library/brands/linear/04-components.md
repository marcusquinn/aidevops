<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Linear — Component Stylings

## Buttons

| Variant | Background | Text | Padding | Radius | Border | Notes |
|---------|-----------|------|---------|--------|--------|-------|
| Ghost (default) | `rgba(255,255,255,0.02)` | `#e2e4e7` | comfortable | 6px | `1px solid rgb(36,40,44)` | Focus shadow: `rgba(0,0,0,0.1) 0px 4px 12px`; standard actions, secondary CTAs |
| Subtle | `rgba(255,255,255,0.04)` | `#d0d6e0` | `0px 6px` | 6px | — | Toolbar actions, contextual buttons |
| Primary Brand | `#5e6ad2` | `#ffffff` | `8px 16px` | 6px | — | Hover: `#828fff`; primary CTAs |
| Icon (circle) | `rgba(255,255,255,0.03)` (resting) · `rgba(255,255,255,0.05)` (hover) | `#f7f8f8` | — | 50% | `1px solid rgba(255,255,255,0.08)` | Close, menu toggle, icon-only actions |
| Pill | transparent | `#d0d6e0` | `0px 10px 0px 5px` | 9999px | `1px solid rgb(35,37,42)` | Filter chips, tags, status indicators |
| Small Toolbar | `rgba(255,255,255,0.05)` | `#62666d` | — | 2px | `1px solid rgba(255,255,255,0.05)` | Shadow: `rgba(0,0,0,0.03) 0px 1.2px 0px 0px`; 12px weight 510; compact toolbar actions, editor controls |

## Cards & Containers

- Background: `rgba(255,255,255,0.02)` to `rgba(255,255,255,0.05)` — never solid, always translucent
- Border: `1px solid rgba(255,255,255,0.08)` (standard) · `1px solid rgba(255,255,255,0.05)` (subtle)
- Radius: 8px (standard) · 12px (featured) · 22px (large panels)
- Shadow: `rgba(0,0,0,0.2) 0px 0px 0px 1px` or layered multi-shadow stacks
- Hover: subtle background opacity increase

## Inputs & Forms

| Variant | Background | Text | Padding | Radius | Notes |
|---------|-----------|------|---------|--------|-------|
| Text Area | `rgba(255,255,255,0.02)` | `#d0d6e0` | `12px 14px` | 6px | Border: `1px solid rgba(255,255,255,0.08)` |
| Search | transparent | `#f7f8f8` | `1px 32px` | — | Icon-aware padding |
| Button-style | — | `#8a8f98` | `1px 6px` | 5px | Focus shadow: multi-layer stack |

## Badges & Pills

| Variant | Background | Text | Padding | Radius | Font | Use |
|---------|-----------|------|---------|--------|------|-----|
| Success Pill | `#10b981` | `#f7f8f8` | — | 50% | 10px weight 510 | Status dots, completion indicators |
| Neutral Pill | transparent | `#d0d6e0` | `0px 10px 0px 5px` | 9999px | 12px weight 510 | Tags, filter chips; border: `1px solid rgb(35,37,42)` |
| Subtle Badge | `rgba(255,255,255,0.05)` | `#f7f8f8` | `0px 8px 0px 2px` | 2px | 10px weight 510 | Inline labels, version tags; border: `1px solid rgba(255,255,255,0.05)` |

## Navigation

- Dark sticky header on near-black background; Linear logomark left-aligned (SVG)
- Links: Inter Variable 13–14px weight 510, `#d0d6e0`; active/hover lightens to `#f7f8f8`
- CTA: brand indigo button or ghost button; mobile: hamburger collapse
- Search: command palette trigger (`/` or `Cmd+K`)

## Image Treatment

- Product screenshots on dark backgrounds; border: `rgba(255,255,255,0.08)`
- Top-rounded images: `12px 12px 0px 0px` radius
- Dashboard/issue previews dominate feature sections
- Shadow beneath screenshots: `rgba(0,0,0,0.4) 0px 2px 4px`
