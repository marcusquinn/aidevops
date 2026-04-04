<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Uber Design: Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow, solid background | Page background, inline content, text sections |
| Subtle (Level 1) | `rgba(0,0,0,0.12) 0px 4px 16px` | Standard content cards, feature blocks |
| Medium (Level 2) | `rgba(0,0,0,0.16) 0px 4px 16px` | Elevated cards, overlay elements |
| Floating (Level 3) | `rgba(0,0,0,0.16) 0px 2px 8px` + translateY(2px) | Floating action buttons, map controls |
| Pressed (Level 4) | `rgba(0,0,0,0.08) inset` (999px spread) | Active/pressed button states |
| Focus Ring | `rgb(255,255,255) 0px 0px 0px 2px inset` | Keyboard focus indicators |

## Shadow Philosophy

Uber uses shadow purely as a structural tool, never decoratively. Shadows are always black at very low opacity (0.08-0.16), creating the bare minimum lift needed to separate content layers. Blur radii are moderate (8-16px) — enough to feel natural but never dramatic. No colored shadows, no layered shadow stacks, no ambient glow effects. Depth is communicated more through the black/white section contrast than through shadow elevation.
