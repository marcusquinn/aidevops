# Design System: OpenCode

Terminal-native, monospace-first design system. Warm near-black (`#201d1d`) background, Berkeley Mono as the sole typeface, flat depth with border-only elevation, Apple HIG semantic colors.

## Chapters

| # | File | Contents |
|---|------|----------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Overall aesthetic, key characteristics, warm dark palette rationale |
| 2 | [02-color-palette.md](02-color-palette.md) | All color tokens: primary, secondary, accent, semantic, text, border |
| 3 | [03-typography.md](03-typography.md) | Berkeley Mono hierarchy, size/weight/line-height scale, principles |
| 4 | [04-components.md](04-components.md) | Buttons, inputs, links, tabs, navigation, terminal hero, feature list |
| 5 | [05-layout.md](05-layout.md) | Spacing system (8px grid), grid/container, whitespace, border radius |
| 6 | [06-depth-elevation.md](06-depth-elevation.md) | Flat elevation model, border levels, no-shadow philosophy |
| 7 | [07-interaction-motion.md](07-interaction-motion.md) | Hover/focus states, three-stage color sequences, minimal transitions |
| 8 | [08-responsive.md](08-responsive.md) | Breakpoints, touch targets, collapsing strategy, image behavior |
| 9 | [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Quick color reference, example component prompts, iteration rules |

## Quick Reference

- **Background**: `#201d1d` (warm near-black, not pure black)
- **Text**: `#fdfcfc` (warm off-white, not pure white)
- **Secondary text**: `#9a9898`
- **Font**: Berkeley Mono (monospace only, no second typeface)
- **Border**: `rgba(15, 0, 0, 0.12)` (warm transparent)
- **Radius**: 4px default, 6px inputs only
- **Shadows**: none — flat terminal aesthetic
- **Accent**: `#007aff` blue | `#ff3b30` red | `#30d158` green | `#ff9f0a` orange
