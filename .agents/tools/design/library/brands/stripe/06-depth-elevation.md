<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow | Page background, inline text |
| Ambient (Level 1) | `rgba(23,23,23,0.06) 0px 3px 6px` | Subtle card lift, hover hints |
| Standard (Level 2) | `rgba(23,23,23,0.08) 0px 15px 35px` | Standard cards, content panels |
| Elevated (Level 3) | `rgba(50,50,93,0.25) 0px 30px 45px -30px, rgba(0,0,0,0.1) 0px 18px 36px -18px` | Featured cards, dropdowns, popovers |
| Deep (Level 4) | `rgba(3,3,39,0.25) 0px 14px 21px -14px, rgba(0,0,0,0.1) 0px 8px 17px -8px` | Modals, floating panels |
| Ring (Accessibility) | `2px solid #533afd` outline | Keyboard focus ring |

## Shadow Philosophy

Stripe's shadow system is built on a principle of chromatic depth. Where most design systems use neutral gray or black shadows, Stripe's primary shadow color (`rgba(50,50,93,0.25)`) is a deep blue-gray that echoes the brand's navy palette. This creates shadows that don't just add depth -- they add brand atmosphere. The multi-layer approach pairs this blue-tinted shadow with a pure black secondary layer (`rgba(0,0,0,0.1)`) at a different offset, creating a parallax-like depth where the branded shadow sits farther from the element and the neutral shadow sits closer. The negative spread values (-30px, -18px) ensure shadows don't extend beyond the element's footprint horizontally, keeping elevation vertical and controlled.

## Decorative Depth

- Dark brand sections (`#1c1e54`) create immersive depth through background color contrast
- Gradient overlays with ruby-to-magenta transitions for hero decorations
- Shadow color `rgba(0,55,112,0.08)` (`--hds-color-shadow-sm-top`) for top-edge shadows on sticky elements
