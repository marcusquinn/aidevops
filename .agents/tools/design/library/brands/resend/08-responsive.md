# Design System: Resend — Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile Small | <480px | Single column, tight padding, 76.8px hero |
| Mobile | 480–600px | Standard mobile, stacked layout |
| Desktop | >600px | Full layout, 96px hero, expanded sections |

*Note: Resend uses a minimal breakpoint system — only 480px and 600px detected. The design is desktop-first with a clean mobile collapse.*

## Touch Targets

- Pill buttons: adequate padding (5px 12px minimum)
- Tab items: 8px radius with comfortable hit areas
- Navigation links spaced with 0.35px tracking for visual separation

## Collapsing Strategy

- Hero: Domaine 96px → 76.8px on mobile
- Navigation: horizontal → hamburger
- Feature sections: side-by-side → stacked
- Code panels: maintain width, horizontal scroll if needed
- Spacing compresses proportionally

## Image Behavior

- Product screenshots maintain aspect ratio
- Dark screenshots blend seamlessly with dark background at all sizes
- Rounded corners (12px–16px) maintained across breakpoints
