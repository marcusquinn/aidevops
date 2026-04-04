<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Component Stylings

## Buttons

### Primary (Green Border)

- Background: `transparent`
- Text: `#ffffff` on dark surfaces, `#000000` on light surfaces
- Padding: 11px 13px
- Border: `2px solid #76b900`
- Radius: 2px
- Font: 16px weight 700
- Hover: background `#1eaedb`, text `#ffffff`
- Active: background `#007fff`, text `#ffffff`, border `1px solid #003eff`, scale(1)
- Focus: background `#1eaedb`, text `#ffffff`, outline `#000000 solid 2px`, opacity 0.9
- Use: Primary CTA ("Learn More", "Explore Solutions")

### Secondary (Green Border Thin)

- Background: transparent
- Border: `1px solid #76b900`
- Radius: 2px
- Use: Secondary actions, alternative CTAs

### Compact / Inline

- Font: 14.4px weight 700
- Letter-spacing: 0.144px
- Line-height: 1.00
- Use: Inline CTAs, compact navigation

## Cards & Containers

- Background: `#ffffff` (light) or `#1a1a1a` (dark sections)
- Border: none (clean edges) or `1px solid #5e5e5e`
- Radius: 2px
- Shadow: `rgba(0, 0, 0, 0.3) 0px 0px 5px 0px` for elevated cards
- Hover: shadow intensification
- Padding: 16-24px internal

## Links

- **On Dark Background**: `#ffffff`, no underline, hover shifts to `#3860be`
- **On Light Background**: `#000000` or `#1a1a1a`, underline `2px solid #76b900`, hover shifts to `#3860be`, underline removed
- **Green Links**: `#76b900`, hover shifts to `#3860be`
- **Muted Links**: `#666666`, hover shifts to `#3860be`

## Navigation

- Dark black background (`#000000`)
- Logo left-aligned, prominent NVIDIA wordmark
- Links: NVIDIA-EMEA 14px weight 700 uppercase, `#ffffff`
- Hover: color shift, no underline change
- Mega-menu dropdowns for product categories
- Sticky on scroll with backdrop

## Image Treatment

- Product/GPU renders as hero images, often full-width
- Screenshot images with subtle shadow for depth
- Green gradient overlays on dark hero sections
- Circular avatar containers with 50% radius

## Distinctive Components

### Product Cards

- Clean white or dark card with minimal radius (2px)
- Green accent border or underline on title
- Bold heading + lighter description pattern
- CTA with green border at bottom

### Tech Spec Tables

- Industrial grid layouts
- Alternating row backgrounds (subtle gray shift)
- Bold labels, regular values
- Green highlights for key metrics

### Cookie/Consent Banner

- Fixed bottom positioning
- Rounded buttons (2px radius)
- Gray border treatments
