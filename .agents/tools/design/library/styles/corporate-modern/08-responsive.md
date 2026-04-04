<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Corporate Modern — Responsive Behaviour

## Breakpoints

| Name | Range | Columns | Gutter | Container Padding |
|------|-------|---------|--------|-------------------|
| Mobile | 0–767px | 4 | 16px | 20px |
| Tablet | 768–1023px | 8 | 24px | 32px |
| Desktop | 1024–1439px | 12 | 24px | 48px |
| Wide | ≥1440px | 12 | 24px | auto (centred 1280px) |

## Touch Targets

- Minimum tap target: 44×44px
- Minimum gap between targets: 8px
- Mobile buttons: full-width below 480px viewport
- Mobile inputs: minimum 48px height

## Mobile-Specific Rules

- Top navigation becomes a bottom tab bar (max 5 items) or hamburger menu
- Multi-column layouts collapse to single column at <768px
- Cards maintain 16px padding on mobile (down from 24px)
- Typography: H1 → 32px, H2 → 26px, H3 → 20px; body remains 16px
- Horizontal scrolling is only acceptable for data tables and carousels with scroll indicators
- Floating action buttons: 56px diameter, 16px from bottom-right
- Section vertical padding: reduce by ~25% from desktop values
- Sticky header height reduces to 56px on mobile
