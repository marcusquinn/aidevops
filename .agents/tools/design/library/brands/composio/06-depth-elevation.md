<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Composio — Depth & Elevation

## Elevation Levels

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow, no border | Page background, inline text |
| Contained (Level 1) | Border Mist 04-08, no shadow | Background groupings, subtle sections |
| Card (Level 2) | Border Mist 10-12, no shadow | Standard content cards, code blocks |
| Brutalist (Level 3) | Hard offset shadow (`4px 4px`, 15% black) | Select interactive cards, distinctive feature highlights |
| Floating (Level 4) | Soft diffuse shadow (`0px 8px 32px`, 50% black) | Modals, overlays, deeply elevated content |

**Shadow Philosophy**: Composio uses shadows sparingly and with deliberate contrast. The hard-offset brutalist shadow is the signature — it breaks the sleek darkness with a raw, almost retro-computing feel. The soft diffuse shadow is reserved for truly floating elements. Most depth is communicated through border opacity gradations rather than shadows.

## Decorative Depth

- **Cyan Glow Halos**: Radial gradient halos using Electric Cyan at low opacity behind feature cards and images. Creates a "screen glow" effect as if the UI elements are emitting light.
- **Blue-Black Gradient Washes**: Linear gradients from Composio Cobalt to Void Black used as section backgrounds, adding subtle color temperature shifts.
- **White Fog Horizon**: A gradient from dark to diffused white/gray at the bottom of the page, creating an atmospheric "dawn" effect before the footer.
