<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Zapier

Warm, approachable professionalism. Cream canvas (`#fffefb`), near-black with reddish warmth (`#201515`), vivid orange accent (`#ff4f00`). Three-font system: Degular Display (hero, 0.90 line-height), Inter (all UI), GT Alpina (editorial accents). Border-first structure -- no shadow elevation.

## Chapters

| File | Contents |
|------|----------|
| [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| [02-color-palette.md](02-color-palette.md) | Full color palette: primary, accent, neutrals, interactive, overlay, shadows |
| [03-typography.md](03-typography.md) | Font families, type hierarchy table, typographic principles |
| [04-components.md](04-components.md) | Buttons, cards, inputs, navigation, image treatment, distinctive components |
| [05-layout.md](05-layout.md) | Spacing system, grid/container, whitespace philosophy, border radius scale |
| [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels, shadow philosophy, decorative depth |
| [07-dos-donts.md](07-dos-donts.md) | Do's and don'ts for consistent implementation |
| [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, image behavior |
| [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example component prompts, iteration guide |

## Quick Reference

```css
Background:   #fffefb  (cream white)
Surface:      #fffdf9  (off-white)
Text Primary: #201515  (zapier black, warm near-black)
Text Body:    #36342e  (dark charcoal)
Text Muted:   #939084  (warm gray)
Border:       #c5c0b1  (sand)
CTA:          #ff4f00  (zapier orange)
```

**Typography**: Degular Display (hero 40-80px, weight 500, line-height 0.90), Inter (all UI), GT Alpina (editorial, thin weight, -1.6px to -1.92px tracking).

**Buttons**: Orange (`#ff4f00`, 4px radius, 8px 16px) for primary CTA. Dark (`#201515`, 8px radius, 20px 24px) for secondary. No pill shapes for primary actions.

**Depth**: Border-first -- `1px solid #c5c0b1` for containment. Inset box-shadow for tab underlines. No traditional shadow elevation.
