<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: ElevenLabs — Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow | Page background, text blocks |
| Inset Edge (Level 0.5) | `rgba(0,0,0,0.075) 0px 0px 0px 0.5px inset, #fff 0px 0px 0px 0px inset` | Internal border definition |
| Outline Ring (Level 1) | `rgba(0,0,0,0.06) 0px 0px 0px 1px` + `rgba(0,0,0,0.04) 0px 1px 2px` + `rgba(0,0,0,0.04) 0px 2px 4px` | Shadow-as-border for cards |
| Card (Level 2) | `rgba(0,0,0,0.4) 0px 0px 1px, rgba(0,0,0,0.04) 0px 4px 4px` | Button elevation, prominent cards |
| Warm Lift (Level 3) | `rgba(78,50,23,0.04) 0px 6px 16px` | Featured CTAs — warm-tinted |
| Focus (Accessibility) | `var(--tw-ring-offset-shadow)` blue ring | Keyboard focus |

**Shadow Philosophy**: ElevenLabs uses the most refined shadow system of any design system analyzed. Every shadow is at sub-0.1 opacity, many include both outward cast AND inward inset components, and the warm CTA shadows use an actual warm color (`rgba(78,50,23,...)`) rather than neutral black. The inset half-pixel borders (`0px 0px 0px 0.5px inset`) create edges so subtle they're felt rather than seen — surfaces define themselves through the lightest possible touch.
