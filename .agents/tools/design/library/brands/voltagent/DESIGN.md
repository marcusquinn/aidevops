<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: VoltAgent

Deep-space command terminal aesthetic for an AI agent engineering platform. Carbon-black canvas, single emerald-green accent, developer-terminal typography.

**Brand identity in one sentence**: Near-pure-black surfaces (`#050507`) with Emerald Signal Green (`#00d992`) as the sole chromatic energy — "power on" for an engineering platform.

## Chapters

| # | File | Contents |
|---|------|----------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| 2 | [02-color-palette.md](02-color-palette.md) | Full color palette: primary, secondary, surfaces, neutrals, semantic, gradients |
| 3 | [03-typography.md](03-typography.md) | Font families, hierarchy table, typographic principles |
| 4 | [04-components.md](04-components.md) | Buttons, cards, inputs, navigation, distinctive components |
| 5 | [05-layout.md](05-layout.md) | Spacing system, grid, whitespace philosophy, border radius scale |
| 6 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels, shadow philosophy, decorative depth |
| 7 | [07-dos-and-donts.md](07-dos-and-donts.md) | Do's and don'ts — what to use and what to avoid |
| 8 | [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, image behavior |
| 9 | [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example component prompts, iteration guide |

## Quick Reference

### Core Colors

| Token | Hex | Role |
|-------|-----|------|
| Emerald Signal Green | `#00d992` | Brand accent — borders, glows, high-signal interactions |
| VoltAgent Mint | `#2fd6a1` | CTA button text on dark surfaces |
| Abyss Black | `#050507` | Page canvas |
| Carbon Surface | `#101010` | Cards, buttons, contained elements |
| Warm Charcoal | `#3d3a39` | Borders, containment |
| Snow White | `#f2f2f2` | Primary text |
| Warm Parchment | `#b8b3b0` | Secondary text |
| Steel Slate | `#8b949e` | Tertiary text, metadata |

### Core Typography

| Role | Font | Size | Weight | Line Height |
|------|------|------|--------|-------------|
| Hero | system-ui | 60px | 400 | 1.00 |
| Section Heading | system-ui | 36px | 400 | 1.11 |
| Body | Inter | 16px | 400–600 | 1.50–1.65 |
| Code | SFMono-Regular | 13–14px | 400 | 1.23–1.43 |

### Elevation at a Glance

| Level | Treatment |
|-------|-----------|
| 0 Flat | No border, no shadow |
| 1 Contained | `1px solid #3d3a39` |
| 2 Emphasized | `3px solid #3d3a39` |
| 3 Accent | `2px solid #00d992` |
| 4 Ambient Glow | `rgba(92,88,85,0.2) 0 0 15px` |
| 5 Dramatic Float | `rgba(0,0,0,0.7) 0 20px 60px` + inset ring |
