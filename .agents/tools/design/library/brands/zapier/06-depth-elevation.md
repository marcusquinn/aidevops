<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow | Page background, text blocks |
| Bordered (Level 1) | `1px solid #c5c0b1` | Standard cards, containers, inputs |
| Strong Border (Level 1b) | `1px solid #36342e` | Dark dividers, emphasized sections |
| Active Tab (Level 2) | `rgb(255, 79, 0) 0px -4px 0px 0px inset` | Active tab underline (orange) |
| Hover Tab (Level 2b) | `rgb(197, 192, 177) 0px -4px 0px 0px inset` | Hover tab underline (sand) |
| Focus (Accessibility) | `1px solid #ff4f00` outline | Focus ring on interactive elements |

**Shadow Philosophy**: Zapier deliberately avoids traditional shadow-based elevation. Structure is defined almost entirely through borders -- warm sand (`#c5c0b1`) borders for standard containment, dark charcoal (`#36342e`) borders for emphasis. The only shadow-like technique is the inset box-shadow used for tab underlines, where a `0px -4px 0px 0px inset` shadow creates a bottom-bar indicator. This border-first approach keeps the design grounded and tangible rather than floating.

## Decorative Depth

- Orange inset underline on active tabs creates visual "weight" at the bottom of elements
- Sand hover underlines provide preview states without layout shifts
- No background gradients in main content -- the cream canvas is consistent
- Footer uses full dark background (`#201515`) for contrast reversal
