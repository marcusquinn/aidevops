<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Apple — Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Small Mobile | <360px | Minimum supported, single column |
| Mobile | 360-480px | Standard mobile layout |
| Mobile Large | 480-640px | Wider single column, larger images |
| Tablet Small | 640-834px | 2-column product grids begin |
| Tablet | 834-1024px | Full tablet layout, expanded nav |
| Desktop Small | 1024-1070px | Standard desktop layout begins |
| Desktop | 1070-1440px | Full layout, max content width |
| Large Desktop | >1440px | Centered with generous margins |

## Touch Targets

- Primary CTAs: 8px 15px padding creating ~44px touch height
- Navigation links: 48px height with adequate spacing
- Media controls: 50% radius circular buttons, minimum 44x44px
- "Learn more" pills: generous padding for comfortable tapping

## Collapsing Strategy

- Hero headlines: 56px Display → 40px → 28px on mobile, maintaining tight line-height proportionally
- Product grids: 3-column → 2-column → single column stacked
- Navigation: full horizontal nav → compact mobile menu (hamburger)
- Product hero modules: full-bleed maintained at all sizes, text scales down
- Section backgrounds: maintain full-width color blocks at all breakpoints — the cinematic rhythm never breaks
- Image sizing: products scale proportionally, never crop — the product silhouette is sacred

## Image Behavior

- Product photography maintains aspect ratio at all breakpoints
- Hero product images scale down but stay centered
- Full-bleed section backgrounds persist at every size
- Lifestyle images may crop on mobile but maintain their rounded corners
- Lazy loading for below-fold product images
