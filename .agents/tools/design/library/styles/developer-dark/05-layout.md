# Design System: Developer Dark — Layout Principles

## Spacing Scale

- Base unit: 4px
- Scale: 2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48, 64

## Grid & Container

- Max content width: 1200px
- Sidebar width: 240px (collapsible)
- Content area: fluid within container
- Gutter: 16px
- Section spacing: 32-48px vertical

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile | < 640px | Single column, sidebar hidden, hamburger menu |
| Tablet | 640-1024px | Sidebar overlay, reduced padding |
| Desktop | 1024-1440px | Full layout, sidebar visible |
| Wide | > 1440px | Max-width contained, centred |

## Whitespace Philosophy

- **Dense by default**: Small gaps, compact padding, tight line-heights. Developers prefer information density.
- **Section breathing room**: 32-48px between major sections prevents wall-of-text feel.
- **Code blocks generous**: Code content gets extra padding (16px) and line-height (1.6) for readability.

## Border Radius Scale

| Size | Value | Use |
|------|-------|-----|
| Default | 4px | Everything -- buttons, cards, inputs, badges |
| Code | 6px | Code blocks, terminal containers |
| Pill | 9999px | Status badges, tags |
