<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Component Stylings

## Buttons

**Primary Orange**
- Background: `#ff4f00`
- Text: `#fffefb`
- Padding: 8px 16px
- Radius: 4px
- Border: `1px solid #ff4f00`
- Use: Primary CTA ("Start free with email", "Sign up free")

**Primary Dark**
- Background: `#201515`
- Text: `#fffefb`
- Padding: 20px 24px
- Radius: 8px
- Border: `1px solid #201515`
- Hover: background shifts to `#c5c0b1`, text to `#201515`
- Use: Large secondary CTA buttons

**Light / Ghost**
- Background: `#eceae3`
- Text: `#36342e`
- Padding: 20px 24px
- Radius: 8px
- Border: `1px solid #c5c0b1`
- Hover: background shifts to `#c5c0b1`, text to `#201515`
- Use: Tertiary actions, filter buttons

**Pill Button**
- Background: `#fffefb`
- Text: `#36342e`
- Padding: 0px 16px
- Radius: 20px
- Border: `1px solid #c5c0b1`
- Use: Tag-like selections, filter pills

**Overlay Semi-transparent**
- Background: `rgba(45, 45, 46, 0.5)`
- Text: `#fffefb`
- Radius: 20px
- Hover: background becomes fully opaque `#2d2d2e`
- Use: Video play buttons, floating actions

**Tab / Navigation (Inset Shadow)**
- Background: transparent
- Text: `#201515`
- Padding: 12px 16px
- Shadow: `rgb(255, 79, 0) 0px -4px 0px 0px inset` (active orange underline)
- Hover shadow: `rgb(197, 192, 177) 0px -4px 0px 0px inset` (sand underline)
- Use: Horizontal tab navigation

## Cards & Containers

- Background: `#fffefb`
- Border: `1px solid #c5c0b1` (warm sand border)
- Radius: 5px (standard), 8px (featured)
- No shadow elevation by default -- borders define containment
- Hover: subtle border color intensification

## Inputs & Forms

- Background: `#fffefb`
- Text: `#201515`
- Border: `1px solid #c5c0b1`
- Radius: 5px
- Focus: border color shifts to `#ff4f00` (orange)
- Placeholder: `#939084`

## Navigation

- Clean horizontal nav on cream background
- Zapier logotype left-aligned, 104x28px
- Links: Inter 16px weight 500, `#201515` text
- CTA: Orange button ("Start free with email")
- Tab navigation uses inset box-shadow underline technique
- Mobile: hamburger collapse

## Image Treatment

- Product screenshots with `1px solid #c5c0b1` border
- Rounded corners: 5-8px
- Dashboard/workflow screenshots prominent in feature sections
- Light gradient backgrounds behind hero content

## Distinctive Components

**Workflow Integration Cards**
- Display connected app icons in pairs
- Arrow or connection indicator between apps
- Sand border containment
- Inter weight 500 for app names

**Stat Counter**
- Large display number using Inter 48px weight 500
- Muted description below in `#36342e`
- Used for social proof metrics

**Social Proof Icons**
- Circular icon buttons: 14px radius
- Sand border: `1px solid #c5c0b1`
- Used for social media follow links in footer
