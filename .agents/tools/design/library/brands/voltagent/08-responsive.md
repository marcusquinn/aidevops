# VoltAgent Design System: Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Small Mobile | <420px | Minimum layout, stacked everything, reduced hero text to ~24px |
| Mobile | 420–767px | Single column, hamburger nav, full-width cards, hero text ~36px |
| Tablet | 768–1024px | 2-column grids begin, condensed nav, medium hero text |
| Desktop | 1025–1440px | Full multi-column layout, expanded nav with dropdowns, large hero (60px) |
| Large Desktop | >1440px | Max-width container centered (est. 1280–1440px), generous horizontal margins |

*23 breakpoints detected in total, ranging from 360px to 1992px — indicating a fluid, heavily responsive grid system rather than fixed breakpoint snapping.*

## Touch Targets

- Buttons use comfortable padding (12px 16px minimum) ensuring adequate touch area
- Navigation links spaced with sufficient gap for thumb navigation
- Interactive card surfaces are large enough to serve as full touch targets
- Minimum recommended touch target: 44x44px

## Collapsing Strategy

- **Navigation**: Full horizontal nav with dropdowns collapses to hamburger menu on mobile
- **Feature grids**: 3-column → 2-column → single-column vertical stacking
- **Hero text**: 60px → 36px → 24px progressive scaling with maintained compression ratios
- **Logo marquee**: Adjusts scroll speed and item sizing; maintains infinite loop
- **Code blocks**: Horizontal scroll on smaller viewports rather than wrapping — preserving code readability
- **Section padding**: Reduces proportionally but maintains generous vertical rhythm between chapters
- **Cards**: Stack vertically on mobile with full-width treatment and maintained internal padding

## Image Behavior

- Dark-themed screenshots and diagrams scale proportionally within containers
- Agent flow diagrams simplify or scroll horizontally on narrow viewports
- Dot-pattern decorative backgrounds scale with viewport
- No visible art direction changes between breakpoints — same crops, proportional scaling
- Lazy loading for below-fold images (Docusaurus default behavior)
