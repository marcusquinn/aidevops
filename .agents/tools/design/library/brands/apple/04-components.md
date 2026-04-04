<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Apple — Component Stylings

> **Apple signature:** Translucent glass nav, pill CTAs, borderless cards, SF Pro typography. Minimal chrome — products dominate.

## Buttons

Shared defaults: Font SF Pro Text 17px weight 400; Focus `2px solid var(--sk-focus-color, #0071E3)` outline.

| Variant | Background | Text | Radius | Notes |
|---------|-----------|------|--------|-------|
| Primary Blue (CTA) | `#0071e3` | `#ffffff` | 8px | Padding 8px 15px; hover brightens; active `#ededf2`; Use: "Buy", "Shop iPhone" |
| Primary Dark | `#1d1d1f` | `#ffffff` | 8px | Padding 8px 15px; Use: secondary CTA, dark variant |
| Pill Link | transparent | `#0066cc` (light) / `#2997ff` (dark) | 980px | Border `1px solid #0066cc`; font 14-17px; hover underline; Use: "Learn more", "Shop" |
| Filter / Search | `#fafafc` | `rgba(0,0,0,0.8)` | 11px | Padding 0 14px; border `3px solid rgba(0,0,0,0.04)`; Use: search bars, filters |
| Media Control | `rgba(210,210,215,0.64)` | `rgba(0,0,0,0.48)` | 50% | Active scale(0.9); focus: white bg, black text; Use: play/pause, carousel arrows |

## Cards & Containers

- Background: `#f5f5f7` (light) or `#272729`–`#2a2a2d` (dark)
- Border: none; Radius: 5px–8px
- Shadow: `rgba(0,0,0,0.22) 3px 5px 30px 0px` for elevated product cards
- Hover: none — cards are static; links within are interactive

## Navigation

- Background: `rgba(0,0,0,0.8)` + `backdrop-filter: saturate(180%) blur(20px)`
- Height: 48px; Text: `#ffffff` 12px weight 400; active: underline on hover
- Logo: Apple SVG logomark, 17×48px, centered or left-aligned
- Mobile: hamburger → full-screen overlay menu

## Image Treatment

- Products on solid fields (black or white) — no backgrounds, no context
- Full-bleed section images spanning full viewport width
- Product photography at high resolution with subtle shadows
- Lifestyle images in rounded containers (12px+ radius)

## Distinctive Components

**Product Hero Module** — full-viewport section, solid bg (black or `#f5f5f7`); SF Pro Display 56px weight 600 headline; one-line descriptor; two pill CTAs ("Learn more" outline + "Buy"/"Shop" filled).

**Product Grid Tile** — square card; product image 60–70% of tile; name + one-line description; "Learn more" / "Shop" pair at bottom.

**Feature Comparison Strip** — horizontal scroll of product variants; each as vertical card with image, name, key specs; minimal chrome.
