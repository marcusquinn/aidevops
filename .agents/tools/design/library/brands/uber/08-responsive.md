<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Uber Design: Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile Small | 320px | Minimum layout, single column, stacked inputs, compact typography |
| Mobile | 600px | Standard mobile, stacked layout, hamburger nav |
| Tablet Small | 768px | Two-column grids begin, expanded card layouts |
| Tablet | 1119px | Full tablet layout, side-by-side hero content |
| Desktop Small | 1120px | Desktop grid activates, horizontal nav pills |
| Desktop | 1136px | Full desktop layout, maximum container width, split hero |

## Touch Targets

- All pill buttons: minimum 44px height (10-14px vertical padding + line-height)
- Navigation chips: generous 14px 16px padding for comfortable thumb tapping
- Circular controls (menu, close): 50% radius ensures large, easy-to-hit targets
- Card surfaces serve as full-area touch targets on mobile

## Collapsing Strategy

- **Navigation**: Horizontal pill nav collapses to hamburger menu with circular toggle
- **Hero**: Split layout (text + map/visual) stacks to single column — text above, visual below
- **Input fields**: Side-by-side pickup/destination inputs stack vertically
- **Feature cards**: 2-column grid collapses to full-width stacked cards
- **Headings**: 52px display scales down through 36px, 32px, 24px, 20px
- **Footer**: Multi-column link grid collapses to accordion or stacked single column
- **Category pills**: Horizontal scroll with overflow on smaller screens

## Image Behavior

- Illustrations scale proportionally within their containers
- Hero imagery maintains aspect ratio, may crop on smaller screens
- QR code sections hide on mobile (app download shifts to direct store links)
- Card imagery maintains 8-12px border radius at all sizes
