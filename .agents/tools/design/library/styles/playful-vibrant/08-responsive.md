# Design System: Playful Vibrant — Responsive Behaviour

## Breakpoints

| Name | Range | Columns | Gutter | Container Padding |
|------|-------|---------|--------|-------------------|
| Mobile | 0–767px | 4 | 16px | 16px |
| Tablet | 768–1023px | 8 | 24px | 32px |
| Desktop | 1024–1439px | 12 | 24px | 48px |
| Wide | ≥1440px | 12 | 24px | auto (centred 1280px) |

## Touch Targets

- Minimum tap target: 48×48px (generous for the target audience)
- Minimum gap between targets: 12px
- Mobile buttons: full-width below 480px, minimum 52px height
- Game/interactive elements: minimum 56×56px

## Mobile-Specific Rules

- Navigation becomes a bottom tab bar (4–5 items with icons + labels, active in `#6366f1`)
- Card grids collapse to single column with 16px gaps
- Cards maintain 20px border-radius on mobile
- Typography: Display → 36px, H1 → 32px, H2 → 26px; Body remains 16px
- Gradients on buttons simplify to solid `#6366f1` on low-power devices
- Micro-interactions maintain — bouncy hover becomes bouncy tap feedback
- Floating action button: 60px diameter, `#6366f1` gradient, 16px from bottom-right
- Section tinted backgrounds remain on mobile — they define content zones
- Horizontal scrolling: acceptable for category pills, sticker/emoji pickers, and image carousels
- Pull-to-refresh: custom animation with brand character/mascot (if applicable)
- Keyboard: suggest emoji/sticker toolbar for social features
