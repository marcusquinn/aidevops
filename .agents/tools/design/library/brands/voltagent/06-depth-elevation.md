<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoltAgent Design System: Depth & Elevation

## Elevation Levels

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow, no border | Page background (`#050507`), inline text |
| Contained (Level 1) | `1px solid #3d3a39`, no shadow | Standard cards, nav bar, code blocks |
| Emphasized (Level 2) | `3px solid #3d3a39`, no shadow | Large interactive buttons, emphasized containers |
| Accent (Level 3) | `2px solid #00d992`, no shadow | Active/highlighted feature cards, selected states |
| Ambient Glow (Level 4) | `rgba(92, 88, 85, 0.2) 0px 0px 15px` | Elevated cards, hover states, soft atmospheric lift |
| Dramatic Float (Level 5) | `rgba(0, 0, 0, 0.7) 0px 20px 60px` + `rgba(148, 163, 184, 0.1) 1px inset` | Hero feature showcase, modals, maximum-elevation content |

**Shadow Philosophy**: VoltAgent communicates depth primarily through **border weight and color**, not shadows. The standard `1px solid #3d3a39` border IS the elevation — adding a `3px` border weight or switching to green (`#00d992`) communicates importance more than adding shadow does. When shadows do appear, they're either warm and diffused (Level 4) or cinematic and dramatic (Level 5) — never medium or generic.

## Decorative Depth

- **Green Signal Glow**: The VoltAgent bolt logo pulses with a `drop-shadow` animation cycling between 2px and 8px blur radius in Emerald Signal Green. This is the most distinctive decorative element — it makes the logo feel "powered on."
- **Warm Charcoal Containment Lines**: The warm tone of `#3d3a39` borders creates a subtle visual warmth against the cool black, as if the cards are faintly heated from within.
- **Dashed Workflow Lines**: `1px dashed rgba(79, 93, 117, 0.4)` creates a blueprint-like aesthetic for architecture diagrams, visually distinct from solid content borders.
