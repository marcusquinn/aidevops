<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Notion — Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow, no border | Page background, text blocks |
| Whisper (Level 1) | `1px solid rgba(0,0,0,0.1)` | Standard borders, card outlines, dividers |
| Soft Card (Level 2) | 4-layer shadow stack (max opacity 0.04) | Content cards, feature blocks |
| Deep Card (Level 3) | 5-layer shadow stack (max opacity 0.05, 52px blur) | Modals, featured panels, hero elements |
| Focus (Accessibility) | `2px solid var(--focus-color)` outline | Keyboard focus on all interactive elements |

**Shadow Philosophy**: Notion's shadow system uses multiple layers with extremely low individual opacity (0.01 to 0.05) that accumulate into soft, natural-looking elevation. The 4-layer card shadow spans from 1.04px to 18px blur, creating a gradient of depth rather than a single hard shadow. The 5-layer deep shadow extends to 52px blur at 0.05 opacity, producing ambient occlusion that feels like natural light rather than computer-generated depth. This layered approach makes elements feel embedded in the page rather than floating above it.

## Decorative Depth

- Hero section: decorative character illustrations (playful, hand-drawn style)
- Section alternation: white to warm white (`#f6f5f4`) background shifts
- No hard section borders -- separation comes from background color changes and spacing
