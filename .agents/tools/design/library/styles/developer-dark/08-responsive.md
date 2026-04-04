# Design System: Developer Dark — Responsive Behaviour

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile | < 640px | Sidebar hidden, hamburger, stacked layout, 12px padding |
| Tablet | 640px–1023px | Sidebar as overlay, 16px padding |
| Desktop | 1024px–1440px | Full layout, sidebar pinned |
| Wide | > 1440px | Content max-width 1200px, centred |

## Touch Targets

- Minimum: 32x32px (denser than standard 44px, acceptable for developer audience)
- Preferred: 40x40px for primary actions
- Mobile override: 44x44px minimum on touch devices

## Mobile Rules

- Sidebar collapses to hamburger overlay
- Code blocks gain horizontal scroll, not wrapping
- Navigation keeps persistent labels on mobile/tablet; primary destinations must display visible text (hover-only labels are not acceptable on touch devices)
- Tables switch to card view below 640px
