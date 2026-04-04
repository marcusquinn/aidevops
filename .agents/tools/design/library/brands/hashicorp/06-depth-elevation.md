<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow | Default surfaces, text blocks |
| Whisper (Level 1) | `rgba(97, 104, 117, 0.05) 0px 1px 1px, rgba(97, 104, 117, 0.05) 0px 2px 2px` | Cards, buttons, interactive surfaces |
| Focus (Level 2) | `3px solid var(--mds-color-focus-action-external)` outline | Focus rings — color-matched to context |

## Shadow Philosophy

HashiCorp uses arguably the subtlest shadow system in modern web design. The dual-layer shadows at 5% opacity are nearly invisible — they exist not to create visual depth but to signal interactivity. If you can see the shadow, it's too strong. This restraint communicates the enterprise value of stability — nothing floats, nothing is uncertain.
