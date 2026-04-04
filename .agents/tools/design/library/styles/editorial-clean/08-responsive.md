<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# 8. Responsive Behaviour

## Breakpoints

| Name | Range | Content Width | Side Padding |
|------|-------|--------------|-------------|
| Mobile | 0–767px | 100% | 20px |
| Tablet | 768–1023px | 680px | auto (centred) |
| Desktop | 1024–1279px | 680px | auto (centred) |
| Wide | ≥1280px | 680px + optional side TOC | auto (centred) |

## Touch Targets

- Minimum tap target: 44×44px
- Navigation links: padded to 48px height on mobile
- Share buttons: minimum 44×44px with 8px gaps

## Mobile-Specific Rules

- Content width: full viewport minus 40px total padding
- Body text: remains 18px (never reduce for mobile — readability first)
- H1: reduces to 32px, H2 to 24px
- Images: full width, may bleed to viewport edges
- Pull quotes: reduce to 22px, left border maintained
- Navigation: collapses to hamburger menu with full-screen overlay
- Sticky TOC: hidden on mobile; replaced by a top "Jump to section" dropdown
- Article cards in listing: stack single-column, image on top
- Footer: stack all columns vertically, generous 32px gaps
- Reading progress bar (optional): thin 2px line at top of viewport in `#4a6fa5`
