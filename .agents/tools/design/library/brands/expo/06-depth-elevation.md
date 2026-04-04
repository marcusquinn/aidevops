<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Expo — Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow | Cloud Gray page background, inline text |
| Surface (Level 1) | White bg, no shadow | Standard white cards on Cloud Gray |
| Whisper (Level 2) | `rgba(0,0,0,0.08) 0px 3px 6px` + `rgba(0,0,0,0.07) 0px 2px 4px` | Subtle card lift, hover states |
| Elevated (Level 3) | `rgba(0,0,0,0.1) 0px 10px 20px` + `rgba(0,0,0,0.05) 0px 3px 6px` | Feature showcases, product screenshots |
| Modal (Level 4) | Dark overlay (`--dialog-overlay-background-color`) + heavy shadow | Dialogs, overlays |

**Shadow Philosophy**: Expo uses shadows as gentle whispers rather than architectural statements. The primary depth mechanism is **background color contrast** — white cards floating on Cloud Gray — rather than shadow casting. When shadows appear, they're soft, diffused, and directional (downward), creating the feeling of paper hovering millimeters above a desk.
