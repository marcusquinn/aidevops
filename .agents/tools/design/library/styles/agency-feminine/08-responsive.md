<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agency Feminine — Responsive Behaviour

## Breakpoint Behaviour

| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 768px) | Single column. Display type scales to 36px serif. Navigation collapses to hamburger with slide-in drawer. Cards stack full-width with reduced padding (24px). Images become full-bleed. |
| Tablet (768–1023px) | Two-column layouts. Display type at 44px. Cards in 2-up grid. Navigation visible or collapsed based on item count. |
| Desktop (1024–1199px) | Full layout. 3-column card grids. All navigation visible. Generous padding and margins. |
| Wide (1200px+) | Content maxes at 1200px container. Extra space is margin. |

## Touch Targets

- Minimum: 48px × 48px tap area
- CTA buttons: 52px minimum height on mobile
- Spacing between tappable elements: 12px minimum
- Form inputs: 52px height on mobile to prevent zoom

## Mobile-Specific Rules

- Serif display type minimum 28px on smallest screens to maintain readability
- Body text increases to 17px on mobile for comfortable reading
- Card padding reduces from 32px to 24px
- Section padding reduces from 120px to 64px vertical
- Pill buttons span full width on mobile for easy tapping
- Image galleries become horizontal scrollers rather than grids
- Honour `prefers-reduced-motion` — disable transforms, keep opacity transitions
