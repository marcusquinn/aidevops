<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Component Stylings

## Buttons

| Variant | Background | Text | Padding | Radius | Border | Hover | Use |
|---------|-----------|------|---------|--------|--------|-------|-----|
| Primary Orange | `#ff4f00` | `#fffefb` | 8px 16px | 4px | `1px solid #ff4f00` | — | Primary CTA ("Start free with email", "Sign up free") |
| Primary Dark | `#201515` | `#fffefb` | 20px 24px | 8px | `1px solid #201515` | bg→`#c5c0b1`, text→`#201515` | Large secondary CTA |
| Light / Ghost | `#eceae3` | `#36342e` | 20px 24px | 8px | `1px solid #c5c0b1` | bg→`#c5c0b1`, text→`#201515` | Tertiary actions, filter buttons |
| Pill | `#fffefb` | `#36342e` | 0px 16px | 20px | `1px solid #c5c0b1` | — | Tag-like selections, filter pills |
| Overlay Semi-transparent | `rgba(45,45,46,0.5)` | `#fffefb` | — | 20px | — | bg→opaque `#2d2d2e` | Video play buttons, floating actions |
| Tab / Navigation | transparent | `#201515` | 12px 16px | — | — | shadow→`rgb(197,192,177) 0px -4px 0px 0px inset` | Horizontal tab navigation |

**Tab active shadow:** `rgb(255,79,0) 0px -4px 0px 0px inset` (orange underline)

## Cards & Containers

- Background: `#fffefb` · Border: `1px solid #c5c0b1` (warm sand) · Radius: 5px standard, 8px featured
- No shadow elevation — borders define containment · Hover: subtle border color intensification

## Inputs & Forms

- Background: `#fffefb` · Text: `#201515` · Border: `1px solid #c5c0b1` · Radius: 5px
- Focus: border→`#ff4f00` · Placeholder: `#939084`

## Navigation

- Horizontal nav on cream background · Zapier logotype left-aligned 104×28px
- Links: Inter 16px weight 500, `#201515` · CTA: Orange button ("Start free with email")
- Tab nav uses inset box-shadow underline technique · Mobile: hamburger collapse

## Image Treatment

- Product screenshots: `1px solid #c5c0b1` border, 5–8px rounded corners
- Dashboard/workflow screenshots prominent in feature sections · Light gradient behind hero content

## Distinctive Components

**Workflow Integration Cards** — connected app icon pairs with arrow/connection indicator, sand border, Inter weight 500 for app names

**Stat Counter** — Inter 48px weight 500 display number, muted description in `#36342e`; used for social proof metrics

**Social Proof Icons** — circular buttons, 14px radius, `1px solid #c5c0b1` sand border; footer social media links
