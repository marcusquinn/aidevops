<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: MongoDB — Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile Small | <425px | Tight single column |
| Mobile | 425–768px | Standard mobile |
| Tablet | 768–1024px | 2-column grids begin |
| Desktop | 1024–1280px | Standard layout |
| Large Desktop | 1280–1440px | Expanded layout |
| Ultra-wide | >1440px | Maximum width, generous margins |

## Touch Targets

- Pill buttons with generous padding
- Navigation links at 16px with adequate spacing
- Card surfaces as full-area touch targets

## Collapsing Strategy

- Hero: MongoDB Value Serif 96px → 64px → scales further
- Navigation: horizontal mega-menu → hamburger
- Feature cards: multi-column → stacked
- Dark/light sections maintain their mode at all sizes
- Source Code Pro labels maintain uppercase treatment

## Image Behavior

- Dashboard screenshots scale proportionally
- Dark section backgrounds maintained full-width
- Image radius maintained across breakpoints
