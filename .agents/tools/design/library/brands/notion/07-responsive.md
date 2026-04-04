# Design System: Notion — Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile Small | <400px | Tight single column, minimal padding |
| Mobile | 400-600px | Standard mobile, stacked layout |
| Tablet Small | 600-768px | 2-column grids begin |
| Tablet | 768-1080px | Full card grids, expanded padding |
| Desktop Small | 1080-1200px | Standard desktop layout |
| Desktop | 1200-1440px | Full layout, maximum content width |
| Large Desktop | >1440px | Centered, generous margins |

## Touch Targets

- Buttons use comfortable padding (8px-16px vertical)
- Navigation links at 15px with adequate spacing
- Pill badges have 8px horizontal padding for tap targets
- Mobile menu toggle uses standard hamburger button

## Collapsing Strategy

- Hero: 64px display -> scales to 40px -> 26px on mobile, maintains proportional letter-spacing
- Navigation: horizontal links + blue CTA -> hamburger menu
- Feature cards: 3-column -> 2-column -> single column stacked
- Product screenshots: maintain aspect ratio with responsive images
- Trust bar logos: grid -> horizontal scroll on mobile
- Footer: multi-column -> stacked single column
- Section spacing: 80px+ -> 48px on mobile

## Image Behavior

- Workspace screenshots maintain whisper border at all sizes
- Hero illustrations scale proportionally
- Product screenshots use responsive images with consistent border radius
- Full-width warm white sections maintain edge-to-edge treatment
