# Design System: Startup Minimal — Responsive Behaviour

## Breakpoint Behaviour

| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 640px) | Single column. Display type drops to 32px. Navigation collapses to icon menu. Cards stack full-width. Inputs go full-width. Table becomes horizontally scrollable. |
| Tablet (640–1023px) | Two-column layouts where applicable. Cards go 2-up. Sidebar becomes top-mounted tabs. |
| Desktop (1024–1199px) | Full layout. Sidebar visible. 3-column grids. All navigation inline. |
| Wide (1200px+) | Content caps at 1200px. Centred with auto margins. |

## Touch Targets

- Minimum: 44px × 44px tap area
- Buttons: 40px minimum height on mobile (padded to 44px tap area)
- Spacing between tappable elements: 8px minimum
- Form inputs: 44px height on mobile

## Mobile-Specific Rules

- Body text stays at 15px — do not reduce
- Card padding reduces from 24px to 16px
- Section padding reduces from 64px to 40px vertical
- Navigation becomes a minimal icon bar or hamburger menu
- Horizontal overflow: hidden on all containers, scroll on tables/code blocks
- Remove hover-only interactions — all information accessible via tap
- Honour `prefers-reduced-motion` — disable all transitions
