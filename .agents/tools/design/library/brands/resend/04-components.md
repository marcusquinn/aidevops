<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Resend — Component Stylings

## Buttons

**Primary Transparent Pill**

- Background: transparent
- Text: `#f0f0f0`
- Padding: 5px 12px
- Radius: 9999px (full pill)
- Border: `1px solid rgba(214, 235, 253, 0.19)` (frost border)
- Hover: background `rgba(255, 255, 255, 0.28)` (white glass)
- Use: Primary CTA on dark backgrounds

**White Solid Pill**

- Background: `#ffffff`
- Text: `#000000`
- Padding: 5px 12px
- Radius: 9999px
- Use: High-contrast CTA ("Get started")

**Ghost Button**

- Background: transparent
- Text: `#f0f0f0`
- Radius: 4px
- No border
- Hover: subtle background tint
- Use: Secondary actions, tab items

## Cards & Containers

- Background: transparent or very subtle dark tint
- Border: `1px solid rgba(214, 235, 253, 0.19)` (frost border)
- Radius: 16px (standard cards), 24px (large sections/panels)
- Shadow: `rgba(176, 199, 217, 0.145) 0px 0px 0px 1px` (ring shadow)
- Dark product screenshots and code demos as card content
- No traditional box-shadow elevation

## Inputs & Forms

- Text: `#f0f0f0` on dark, `#000000` on light
- Radius: 4px
- Focus: shadow-based ring
- Minimal styling — inherits dark theme

## Navigation

- Sticky dark header with frost border bottom: `1px solid rgba(214, 235, 253, 0.19)`
- "Resend" wordmark left-aligned
- ABC Favorit 14px weight 500 with +0.35px tracking for nav links
- Pill CTAs right-aligned
- Mobile: hamburger collapse

## Image Treatment

- Product screenshots and code demos dominate content sections
- Dark-themed screenshots on dark background — seamless integration
- Rounded corners: 12px–16px on images
- Full-width sections with subtle gradient overlays

## Distinctive Components

**Tab Navigation**

- Horizontal tabs with subtle selection indicator
- Tab items: 8px radius
- Active state with subtle background differentiation

**Code Preview Panels**

- Dark code blocks using Commit Mono
- Frost borders (`rgba(214, 235, 253, 0.19)`)
- Syntax-highlighted with multi-color accent tokens (orange, blue, green, yellow)

**Multi-color Accent Badges**

- Each product feature has its own accent color from the CSS variable scale
- Badges use the accent color at low opacity (12–42%) for background, full opacity for text
