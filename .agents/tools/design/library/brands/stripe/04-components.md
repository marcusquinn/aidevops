<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Component Stylings

## Buttons

| Variant | Background | Text | Border | Hover | Use |
|---------|-----------|------|--------|-------|-----|
| Primary Purple | `#533afd` | `#ffffff` | — | bg→`#4434d4` | Primary CTA ("Start now", "Contact sales") |
| Ghost / Outlined | transparent | `#533afd` | `1px solid #b9b9f9` | bg→`rgba(83,58,253,0.05)` | Secondary actions |
| Transparent Info | transparent | `#2874ad` | `1px solid rgba(43,145,223,0.2)` | — | Tertiary/info-level actions |
| Neutral Ghost | `rgba(255,255,255,0)` | `rgba(16,16,16,0.3)` | outline `1px solid rgb(212,222,233)` | — | Disabled or muted actions |

**Default button:** Padding 8px 16px · Radius 4px · Font 16px sohne-var weight 400 `"ss01"`

## Cards & Containers

- Background: `#ffffff` · Border: `1px solid #e5edf5` (standard) or `1px solid #061b31` (dark accent)
- Radius: 4px (tight), 5px (standard), 6px (comfortable), 8px (featured)
- Shadow (standard): `rgba(50,50,93,0.25) 0px 30px 45px -30px, rgba(0,0,0,0.1) 0px 18px 36px -18px`
- Shadow (ambient): `rgba(23,23,23,0.08) 0px 15px 35px 0px`
- Hover: shadow intensifies, often adding the blue-tinted layer

## Badges / Tags / Pills

| Variant | Background | Text | Padding | Border | Font |
|---------|-----------|------|---------|--------|------|
| Neutral Pill | `#ffffff` | `#000000` | 0px 6px | `1px solid #f6f9fc` | 11px weight 400 |
| Success Badge | `rgba(21,190,83,0.2)` | `#108c3d` | 1px 6px | `1px solid rgba(21,190,83,0.4)` | 10px weight 300 |

**Default badge:** Radius 4px

## Inputs & Forms

- Border: `1px solid #e5edf5` · Radius: 4px · Focus: `1px solid #533afd` or purple ring
- Label: `#273951`, 14px sohne-var · Text: `#061b31` · Placeholder: `#64748d`

## Navigation

- Horizontal nav on white, sticky with blur backdrop · Brand logotype left-aligned
- Links: sohne-var 14px weight 400, `#061b31` with `"ss01"` · Radius: 6px on nav container
- CTA: purple button right-aligned ("Sign in", "Start now") · Mobile: hamburger toggle 6px radius

## Decorative Elements

- Dashed borders: `1px dashed #362baa` (purple, placeholder/drop zones) · `1px dashed #ffd7ef` (magenta, decorative)
- Gradient accents: ruby-to-magenta (`#ea2261` → `#f96bee`) for hero decorations
- Brand dark sections: `#1c1e54` background with white text
