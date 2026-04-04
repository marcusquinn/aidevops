<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Sanity — Responsive Behavior

## Breakpoints

| Name | Width | Behavior |
|------|-------|----------|
| Desktop XL | >= 1640px | Full layout, maximum content width |
| Desktop | >= 1440px | Standard desktop layout |
| Desktop Compact | >= 1200px | Slightly condensed desktop |
| Laptop | >= 1100px | Reduced column widths |
| Tablet Landscape | >= 960px | 2-column layouts begin collapsing |
| Tablet | >= 768px | Transition zone, some elements stack |
| Mobile Large | >= 720px | Near-tablet layout |
| Mobile | >= 480px | Single-column, stacked layout |
| Mobile Small | >= 376px | Minimum supported width |

## Collapsing Strategy

- **Navigation**: Horizontal links collapse to hamburger menu below 768px
- **Hero typography**: Scales from 112px -> 72px -> 48px -> 38px across breakpoints, maintaining tight letter-spacing ratios
- **Grid layouts**: 3-column -> 2-column at ~960px, single-column below 768px
- **Card grids**: Horizontal scrolling on mobile instead of wrapping (preserving card aspect ratios)
- **Section spacing**: Vertical padding reduces by ~40% on mobile (120px -> 64px -> 48px)
- **Button sizing**: CTA pills maintain padding but reduce font size; ghost buttons stay fixed
- **Code blocks**: Horizontal scroll with preserved monospace formatting

## Mobile-Specific Adjustments

- Full-bleed sections extend edge-to-edge with 16px internal gutters
- Touch targets: minimum 44px for all interactive elements
- Heading letter-spacing relaxes slightly at mobile sizes (less aggressive negative tracking)
- Image containers switch from fixed aspect ratios to full-width with auto height
