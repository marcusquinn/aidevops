<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Vercel

Gallery-like minimalism as engineering principle. Near-pure white canvas (`#ffffff`) with near-black (`#171717`) text. Geist font family with aggressive negative letter-spacing at display sizes. Shadow-as-border philosophy replaces traditional CSS borders throughout. Workflow accent colors (Ship Red, Preview Pink, Develop Blue) mark pipeline stages only.

## Chapters

| File | Contents |
|------|----------|
| [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| [02-color-palette.md](02-color-palette.md) | Full color palette: primary, workflow accents, console, interactive, neutrals, surface, shadows |
| [03-typography.md](03-typography.md) | Font families, type hierarchy table, typographic principles |
| [04-components.md](04-components.md) | Buttons, cards, inputs, navigation, image treatment, distinctive components |
| [05-layout.md](05-layout.md) | Spacing system, grid/container, whitespace philosophy, border radius scale |
| [06-depth-elevation.md](06-depth-elevation.md) | Shadow levels table, shadow philosophy, decorative depth |
| [07-dos-donts.md](07-dos-donts.md) | Do's and don'ts for consistent implementation |
| [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, image behavior |
| [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example component prompts, iteration guide |

## Quick Reference

```css
Background:      #ffffff
Text Primary:    #171717
Text Secondary:  #4d4d4d
Border (shadow): rgba(0,0,0,0.08) 0px 0px 0px 1px
Link:            #0072f5
Focus ring:      hsla(212, 100%, 48%, 1)
Ship Red:        #ff5b4f
Preview Pink:    #de1d8d
Develop Blue:    #0a72ef
```

**Typography**: Geist Sans (display + body), Geist Mono (code/labels). Display: -2.4px to -2.88px letter-spacing, 1.00–1.17 line-height. Three weights: 400 (body), 500 (UI), 600 (headings).

**Buttons**: 6px radius for primary/secondary. 9999px for badges/tags only. Shadow-border (`rgb(235,235,235) 0px 0px 0px 1px`) on white buttons.

**Depth**: Shadow-as-border only — `rgba(0,0,0,0.08) 0px 0px 0px 1px`. Multi-layer card stack adds `rgba(0,0,0,0.04) 0px 2px 2px` + inner `#fafafa` ring.
