<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: OpenCode — Agent Prompt Guide

## Quick Color Reference

- Page background: `#201d1d` (warm near-black)
- Primary text: `#fdfcfc` (warm off-white)
- Secondary text: `#9a9898` (warm gray)
- Muted text: `#6e6e73`
- Accent: `#007aff` (blue)
- Danger: `#ff3b30` (red)
- Success: `#30d158` (green)
- Warning: `#ff9f0a` (orange)
- Button bg: `#201d1d`, button text: `#fdfcfc`
- Border: `rgba(15, 0, 0, 0.12)` (warm transparent)
- Input bg: `#f8f7f7`, input border: `rgba(15, 0, 0, 0.12)`

## Example Component Prompts

- "Create a hero section on `#201d1d` warm dark background. Headline at 38px Berkeley Mono weight 700, line-height 1.50, color `#fdfcfc`. Subtitle at 16px weight 400, color `#9a9898`. Primary CTA button (`#201d1d` bg with `1px solid #646262` border, 4px radius, 4px 20px padding, `#fdfcfc` text at weight 500)."
- "Design a feature list: single-column on `#201d1d` background. Feature name at 16px Berkeley Mono weight 700, color `#fdfcfc`. Description at 16px weight 400, color `#9a9898`. No cards, no borders -- pure text with 16px vertical gap between items."
- "Build an email capture form: `#f8f7f7` background input, `1px solid rgba(15, 0, 0, 0.12)` border, 6px radius, 20px padding. Adjacent dark button (`#201d1d` bg, `#fdfcfc` text, 4px radius, 4px 20px padding). Berkeley Mono throughout."
- "Create navigation: sticky `#201d1d` background. 16px Berkeley Mono weight 500 for links, `#fdfcfc` text. Brand name left-aligned in monospace. Links with underline decoration. No blur, no transparency -- solid dark surface."
- "Design a footer: `#201d1d` background, multi-column link grid. Links at 16px Berkeley Mono weight 400, color `#9a9898`. Section headers at weight 700. Border-top `1px solid rgba(15, 0, 0, 0.12)` separator."

## Iteration Guide

1. Berkeley Mono is the only font -- never introduce a second typeface. Size and weight create all hierarchy.
2. Keep surfaces flat: no shadows, no gradients, no blur effects. Use borders and background shifts only.
3. The warm undertone matters: use `#201d1d` not `#000000`, use `#fdfcfc` not `#ffffff`. The reddish warmth is subtle but essential.
4. Border radius is 4px everywhere except inputs (6px). Never use rounded pills or large radii.
5. Semantic colors follow Apple HIG: `#007aff` blue, `#ff3b30` red, `#30d158` green, `#ff9f0a` orange. Each has hover and active darkened variants.
6. Three-stage interaction: default → hover (darkened) → active (deeply darkened) for all semantic colors.
7. Borders use `rgba(15, 0, 0, 0.12)` -- a warm transparent dark, not neutral gray. This ties borders to the warm palette.
8. Spacing follows an 8px grid: 8, 16, 24, 32, 40, 48, 64, 80, 96px. Use 4px for fine adjustments only.
