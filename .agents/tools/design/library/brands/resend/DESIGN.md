<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Resend

Resend — cinematic dark canvas: pure black void, near-white text, icy frost borders (`rgba(214,235,253,0.19)`), three-font editorial hierarchy (Domaine Display hero, ABC Favorit sections, Inter body), pill CTAs, multi-color accent scales.

## Chapters

| File | Contents |
|------|----------|
| [01-visual-theme.md](01-visual-theme.md) | Visual identity, atmosphere, key characteristics |
| [02-color-palette.md](02-color-palette.md) | Primary, accent scales (orange/green/blue/yellow/red), neutral, surface, border/shadow colors |
| [03-typography.md](03-typography.md) | Font families, type scale table, typographic principles |
| [04-components.md](04-components.md) | Buttons, cards, inputs, navigation, image treatment, distinctive components |
| [05-layout.md](05-layout.md) | Spacing system, grid, whitespace philosophy, border radius scale |
| [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels table, shadow philosophy, decorative depth |
| [07-dos-donts.md](07-dos-donts.md) | Do/Don't rules for Resend brand compliance |
| [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, image behavior |
| [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example component prompts, iteration guide |

## Quick Reference

- **Background**: Void Black (`#000000`) — non-negotiable
- **Primary text**: Near White (`#f0f0f0`)
- **Secondary text**: Silver (`#a1a4a5`)
- **Border**: Frost Border (`rgba(214, 235, 253, 0.19)`) — the signature, never neutral gray
- **Orange accent**: `#ff801f` (`--color-orange-10`)
- **Green accent**: `#11ff99` at 18% opacity (`--color-green-4`)
- **Blue accent**: `#3b9eff` (`--color-blue-10`)
- **Fonts**: `domaine` (hero 96px), `aBCFavorit` (sections 56px), `inter` (body), `commitMono` (code)
- **OpenType**: `"ss01"`, `"ss03"`, `"ss04"`, `"ss11"` on all display fonts — mandatory
- **CTA radius**: 9999px pill — transparent with frost border (dark) or white solid (high-contrast)
- **Shadow**: Ring `rgba(176, 199, 217, 0.145) 0px 0px 0px 1px` — no traditional box-shadows
