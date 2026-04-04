<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Startup Bold — Responsive Behaviour

## Breakpoint Behaviour

| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 640px) | Single column. Display type scales to 36px. Hero CTAs stack vertically full-width. Card grid stacks. Navigation collapses to hamburger. Pricing cards stack. Logo grid becomes 2-up. |
| Tablet (640–1023px) | Two-column layouts. Display type at 48px. Card grid goes 2-up. Side-by-side hero layout stacks but images remain inline. |
| Desktop (1024–1279px) | Full layout. 3-column card grids. Pricing comparison side-by-side. All navigation visible. |
| Wide (1280px+) | Content maxes at 1280px. 4-column feature grids where applicable. |

## Touch Targets

- Minimum: 44px × 44px tap area
- CTA buttons: 48px minimum height on mobile
- Spacing between tappable elements: 8px minimum
- Form inputs: 48px height on mobile

## Mobile-Specific Rules

- Hero CTA buttons become full-width and stack vertically
- Card padding reduces from 28px to 20px
- Section vertical padding reduces by ~40% (96px → 56px)
- Body text stays at 16px — never reduce for mobile
- Sticky mobile CTA bar at bottom for key conversion pages
- Logo grids become horizontally scrollable carousels
- Honour `prefers-reduced-motion` — disable transforms, keep fade transitions
