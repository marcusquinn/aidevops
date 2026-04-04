# Design System: Composio — Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile | <768px | Single column, hamburger nav, full-width cards, reduced section padding, hero text scales down to ~28-40px |
| Tablet | 768-1024px | 2-column grid for cards, condensed nav, slightly reduced hero text |
| Desktop | 1024-1440px | Full multi-column layout, expanded nav with all links visible, large hero typography (64px) |
| Large Desktop | >1440px | Max-width container centered, generous horizontal margins |

## Touch Targets

- Minimum touch target: 44x44px for all interactive elements
- Buttons use comfortable padding (8px 24px minimum) ensuring adequate touch area
- Nav links spaced with sufficient gap for thumb navigation

## Collapsing Strategy

- **Navigation**: Full horizontal nav on desktop collapses to hamburger on mobile
- **Feature grids**: 3-column → 2-column → single-column stacking
- **Hero text**: 64px → 40px → 28px progressive scaling
- **Section padding**: Reduces proportionally but maintains generous vertical rhythm
- **Cards**: Stack vertically on mobile with full-width treatment
- **Code blocks**: Horizontal scroll on smaller viewports rather than wrapping

## Image Behavior

- Product screenshots scale proportionally within their containers
- Dark-themed images maintain contrast on the dark background at all sizes
- Gradient glow effects scale with container size
- No visible art direction changes between breakpoints — same crops, proportional scaling
