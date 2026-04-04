<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Sanity

Nocturnal command-center aesthetic. Near-black canvas (`#0b0b0b`), achromatic gray scale, vivid accent punctuation (coral-red CTA, electric blue hover, neon green success). waldenburgNormal with extreme negative tracking at display sizes; IBM Plex Mono for technical labels.

## Chapters

| File | Contents |
|------|----------|
| [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| [02-color-palette.md](02-color-palette.md) | Full color palette: brand, accent, surface, neutrals, semantic, borders |
| [03-typography.md](03-typography.md) | Font families, type hierarchy table, typographic principles |
| [04-components.md](04-components.md) | Buttons, cards, inputs, navigation, badges |
| [05-layout.md](05-layout.md) | Spacing system, grid/container, whitespace philosophy, border radius scale |
| [06-depth-elevation.md](06-depth-elevation.md) | Shadow system, colorimetric depth philosophy |
| [07-dos-donts.md](07-dos-donts.md) | Do's and don'ts for consistent implementation |
| [08-responsive.md](08-responsive.md) | Breakpoints, collapsing strategy, mobile adjustments |
| [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example prompts, iteration guide |

## Quick Reference

```css
Background:      #0b0b0b
Surface:         #212121
Border:          #353535 (visible) / #212121 (subtle)
Text Primary:    #ffffff
Text Secondary:  #b9b9b9
CTA:             #f36458 (coral-red)
Interactive:     #0052ef (electric blue, all hovers)
Success:         #19d600
Error:           #dd0000
```

**Typography**: waldenburgNormal (display + body), IBM Plex Mono (code/labels). Display headings: -2.88px to -4.48px letter-spacing, 1.00-1.24 line-height. Body: 1.50 line-height.

**Buttons**: Full pill (99999px) for primary/secondary. 5-6px radius for ghost/subtle. All hover to `#0052ef`.

**Depth**: Colorimetric only — `#0b0b0b` → `#212121` → `#353535` → `#ffffff`. No offset shadows.
