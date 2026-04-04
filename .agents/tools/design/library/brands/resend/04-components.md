<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Resend — Component Stylings

Frost border (shared): `1px solid rgba(214, 235, 253, 0.19)`
Pill padding (shared): `5px 12px`

## Buttons

**Primary Transparent Pill** — Primary CTA on dark backgrounds
- Background: transparent; Text: `#f0f0f0`; Radius: 9999px
- Border: frost border; Hover: `rgba(255, 255, 255, 0.28)` (white glass)

**White Solid Pill** — High-contrast CTA ("Get started")
- Background: `#ffffff`; Text: `#000000`; Radius: 9999px

**Ghost Button** — Secondary actions, tab items
- Background: transparent; Text: `#f0f0f0`; Radius: 4px; No border
- Hover: subtle background tint

## Cards & Containers

- Background: transparent or very subtle dark tint; Radius: 16px (cards), 24px (panels)
- Border: frost border; Shadow: `rgba(176, 199, 217, 0.145) 0px 0px 0px 1px` (ring)
- Content: dark product screenshots, code demos; No box-shadow elevation

## Inputs & Forms

- Text: `#f0f0f0` (dark), `#000000` (light); Radius: 4px
- Focus: shadow-based ring; Minimal styling — inherits dark theme

## Navigation

- Sticky dark header; border-bottom: frost border; "Resend" wordmark left-aligned
- Nav links: ABC Favorit 14px weight 500 +0.35px tracking; Pill CTAs right-aligned
- Mobile: hamburger collapse

## Image Treatment

- Product screenshots dominate content sections; dark-on-dark — seamless integration
- Rounded corners: 12px–16px; Full-width sections with subtle gradient overlays

## Distinctive Components

**Tab Navigation**
- Horizontal tabs; Tab items: 8px radius; Active: subtle background differentiation

**Code Preview Panels**
- Dark code blocks (Commit Mono); Frost borders; Syntax-highlighted: orange, blue, green, yellow

**Multi-color Accent Badges**
- Per-feature accent color from CSS variable scale
- Badge background: accent at 12–42% opacity; text: full opacity
