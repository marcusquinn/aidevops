<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: OpenCode — Depth & Elevation

## Elevation Levels

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow, no border | Default state for most elements |
| Border Subtle (Level 1) | `1px solid rgba(15, 0, 0, 0.12)` | Section dividers, input borders, horizontal rules |
| Border Tab (Level 2) | `2px solid #9a9898` bottom only | Active tab indicator |
| Border Outline (Level 3) | `1px solid #646262` | Container outlines, elevated elements |

**Shadow Philosophy**: OpenCode's depth system is intentionally flat. There are no box-shadows in the extracted tokens -- zero shadow values were detected. Depth is communicated exclusively through border treatments and background color shifts. This flatness is consistent with the terminal aesthetic: terminals don't have shadows, and neither does OpenCode. The three border levels (transparent warm, tab indicator, solid outline) create sufficient visual hierarchy without any elevation illusion.

## Decorative Depth

- Background color shifts between `#201d1d` and `#302c2c` create subtle surface differentiation
- Transparent borders at 12% opacity provide barely-visible structure
- The warm reddish tint in border colors (`rgba(15, 0, 0, 0.12)`) ties borders to the overall warm dark palette
- No gradients, no blurs, no ambient effects -- pure flat terminal aesthetic
