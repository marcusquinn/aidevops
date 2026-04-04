# Design System: Resend — Agent Prompt Guide

## Quick Color Reference

- Background: Void Black (`#000000`)
- Primary text: Near White (`#f0f0f0`)
- Secondary text: Silver (`#a1a4a5`)
- Border: Frost Border (`rgba(214, 235, 253, 0.19)`)
- Orange accent: `#ff801f`
- Green accent: `#11ff99` (at 18% opacity)
- Blue accent: `#3b9eff`
- Focus ring: `rgb(0, 0, 0) 0px 0px 0px 8px`

## Example Component Prompts

- "Create a hero section on pure black (#000000) background. Headline at 96px Domaine Display weight 400, line-height 1.00, letter-spacing -0.96px, near-white (#f0f0f0) text, OpenType 'ss01 ss04 ss11'. Subtitle at 20px ABC Favorit weight 400, line-height 1.30. Two pill buttons: white solid (#ffffff, 9999px radius) and transparent with frost border (rgba(214,235,253,0.19))."
- "Design a navigation bar: dark background with frost border bottom (1px solid rgba(214,235,253,0.19)). Nav links at 14px ABC Favorit weight 500, letter-spacing +0.35px, OpenType 'ss01 ss03 ss04'. White pill CTA right-aligned."
- "Build a feature card: transparent background, frost border (rgba(214,235,253,0.19)), 16px radius. Title at 56px ABC Favorit weight 400, letter-spacing -2.8px. Body at 16px Inter weight 400, #a1a4a5 text."
- "Create a code block using Commit Mono 16px on dark background. Frost border container (24px radius). Syntax colors: orange (#ff801f), blue (#3b9eff), green (#11ff99), yellow (#ffc53d)."
- "Design an accent badge: background #ff5900 at 22% opacity, text #ffa057, 9999px radius, 12px Inter weight 500."

## Iteration Guide

1. Start with pure black — everything floats in the void
2. Frost borders (`rgba(214, 235, 253, 0.19)`) are the universal structural element — not gray, not neutral
3. Three fonts, three roles: Domaine (hero), ABC Favorit (sections), Inter (body) — never cross
4. OpenType stylistic sets are mandatory on display fonts — they define the character
5. Multi-color accents at low opacity (12–42%) for backgrounds, full opacity for text
6. Pill shape (9999px) for CTAs and badges, standard radius (4px–16px) for containers
7. No shadows — use frost borders for depth against the void
