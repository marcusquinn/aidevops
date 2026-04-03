# Agency Techie — Responsive Behaviour

## Breakpoint Behaviour

| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 640px) | Single column. Navigation collapses to hamburger. Cards stack full-width. Code blocks gain horizontal scroll. Font sizes reduce by 1 step. |
| Tablet (640–1023px) | Two-column where applicable. Sidebar collapses to top tabs. Card grid becomes 2-up. |
| Desktop (1024–1279px) | Full layout. Sidebar visible. 3-column card grids. All navigation visible. |
| Wide (1280px+) | Content maxes at 1280px container. Extra space becomes margin. |

## Touch Targets

- Minimum: 44px × 44px tap area (even if visually smaller)
- Spacing between tappable elements: minimum 8px
- Mobile nav items: 48px minimum height

## Mobile-Specific Rules

- Code blocks: horizontal scroll with `-webkit-overflow-scrolling: touch`
- Tables: horizontal scroll wrapper with shadow fade indicators on edges
- Reduce card padding from 20px to 16px
- Stack side-by-side layouts at 640px breakpoint
- Increase body font to 16px to prevent iOS zoom
