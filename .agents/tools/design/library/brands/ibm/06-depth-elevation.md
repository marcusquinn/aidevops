<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Design: Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow, `#ffffff` background | Default page surface |
| Layer 01 | No shadow, `#f4f4f4` background | Cards, tiles, alternating sections |
| Layer 02 | No shadow, `#e0e0e0` background | Elevated panels within Layer 01 |
| Raised | `0 2px 6px rgba(0,0,0,0.3)` | Dropdowns, tooltips, overflow menus |
| Overlay | `0 2px 6px rgba(0,0,0,0.3)` + dark scrim | Modal dialogs, side panels |
| Focus | `2px solid #0f62fe` inset + `1px solid #ffffff` | Keyboard focus ring |
| Bottom-border | `2px solid #161616` on bottom edge | Active input, active tab indicator |

**Shadow Philosophy**: Carbon is deliberately shadow-averse. IBM achieves depth primarily through background-color layering — stacking surfaces of progressively darker grays rather than adding box-shadows. This creates a flat, print-inspired aesthetic where hierarchy is communicated through color value, not simulated light. Shadows are reserved exclusively for floating elements (dropdowns, tooltips, modals) where the element genuinely overlaps content. This restraint gives the rare shadow meaningful impact — when something floats in Carbon, it matters.
