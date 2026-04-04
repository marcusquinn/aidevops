<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Corporate Friendly — Responsive Behaviour

## Breakpoints

| Name | Range | Columns | Gutter | Container Padding |
|------|-------|---------|--------|-------------------|
| Mobile | 0–767px | 4 | 16px | 20px |
| Tablet | 768–1023px | 8 | 24px | 32px |
| Desktop | 1024–1279px | 12 | 24px | 48px |
| Wide | ≥1280px | 12 | 24px | auto (centred 1200px) |

## Touch Targets

- Minimum tap target: 48×48px (larger than standard 44px for friendliness)
- Minimum gap between targets: 12px
- Mobile buttons: full-width below 480px
- Checkboxes and radio buttons: minimum 24×24px visible target

## Mobile-Specific Rules

- Top navigation becomes a hamburger menu or bottom tab bar at <768px
- Card grid becomes single-column stacked layout
- Cards maintain 20px padding on mobile (down from 28px)
- Typography: H1 → 28px, H2 → 24px, Body remains 16px
- Form fields stack vertically; inline field groups become full-width
- CTAs stick to bottom of viewport on key conversion pages
- Section padding reduces: 80px → 48px, 48px → 32px
- Image aspect ratios maintain; hero images may crop to 4:3 on mobile
- Floating tooltips become inline expandable help text
