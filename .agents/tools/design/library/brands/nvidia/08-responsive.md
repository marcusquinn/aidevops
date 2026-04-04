<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Responsive Behavior

## Breakpoints

| Name | Width | Key Changes |
|------|-------|-------------|
| Mobile Small | <375px | Compact single-column, reduced padding |
| Mobile | 375–425px | Standard mobile layout |
| Mobile Large | 425–600px | Wider mobile, 2-col hints |
| Tablet Small | 600–768px | 2-column grids begin |
| Tablet | 768–1024px | Full card grids, expanded nav |
| Desktop | 1024–1350px | Standard desktop layout |
| Large Desktop | >1350px | Max content width, generous margins |

## Touch Targets

- Buttons: 11px 13px padding
- Nav links: 14px uppercase, adequate spacing
- Green-bordered buttons: high-contrast on dark backgrounds
- Mobile: hamburger menu with full-screen overlay

## Collapsing Strategy

- Hero heading: 36px → proportional scale-down
- Nav: horizontal → hamburger at ~1024px
- Product cards: 3-col → 2-col → single-col
- Footer: multi-col → single stacked column
- Section spacing: 64–80px → 32–48px on mobile
- Images: maintain aspect ratio, scale to container width

## Image Behavior

- GPU/product renders: high resolution at all sizes
- Hero images: scale proportionally with viewport
- Card images: consistent aspect ratios
- Full-bleed dark sections: edge-to-edge treatment

## Typography Scaling

- Display: 36px → ~24px on mobile
- Section headings: 24px → ~20px on mobile
- Body: 15–16px (unchanged across breakpoints)
- Button text: 16px (unchanged)

## Dark/Light Section Strategy

See `01-visual-theme.md` for full surface philosophy. Responsive behavior:

- Dark (black bg, white text) alternates with light (white bg, black text)
- Green accent consistent across both surface types
- Dark: links white, underlines green
- Light: links black, underlines green
