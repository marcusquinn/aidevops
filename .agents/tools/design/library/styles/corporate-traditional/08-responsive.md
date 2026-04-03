# Design System: Corporate Traditional — Responsive Behaviour

## Breakpoints

| Name | Range | Columns | Gutter | Behaviour |
|------|-------|---------|--------|-----------|
| Mobile | 0–767px | 4 | 16px | Single column, stacked layout |
| Tablet | 768–1023px | 8 | 16px | Sidebar collapses, 2-col grids |
| Desktop | 1024–1279px | 12 | 24px | Full layout, sidebar visible |
| Wide | ≥1280px | 12 | 24px | Centred container, max 1200px |

## Touch Targets

- Minimum tap target: 44×44px
- Minimum spacing between tap targets: 8px
- Mobile button padding: minimum 14px vertical

## Mobile-Specific Rules

- Navigation collapses to hamburger menu at <768px
- Sidebar content moves below main content
- Tables become horizontally scrollable with `-webkit-overflow-scrolling: touch`
- Font sizes reduce: H1 → 28px, H2 → 22px, Body remains 16px
- Section vertical padding reduces by ~33% (e.g., 96px → 64px)
- Cards stack full-width with 16px gap
- Gold accent elements maintain visibility — do not hide on mobile
