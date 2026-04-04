<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Notion — Agent Prompt Guide

## Quick Color Reference

- Primary CTA: Notion Blue (`#0075de`)
- Background: Pure White (`#ffffff`)
- Alt Background: Warm White (`#f6f5f4`)
- Heading text: Near-Black (`rgba(0,0,0,0.95)`)
- Body text: Near-Black (`rgba(0,0,0,0.95)`)
- Secondary text: Warm Gray 500 (`#615d59`)
- Muted text: Warm Gray 300 (`#a39e98`)
- Border: `1px solid rgba(0,0,0,0.1)`
- Link: Notion Blue (`#0075de`)
- Focus ring: Focus Blue (`#097fe8`)

## Example Component Prompts

- "Create a hero section on white background. Headline at 64px NotionInter weight 700, line-height 1.00, letter-spacing -2.125px, color rgba(0,0,0,0.95). Subtitle at 20px weight 600, line-height 1.40, color #615d59. Blue CTA button (#0075de, 4px radius, 8px 16px padding, white text) and ghost button (transparent bg, near-black text, underline on hover)."
- "Design a card: white background, 1px solid rgba(0,0,0,0.1) border, 12px radius. Use shadow stack: rgba(0,0,0,0.04) 0px 4px 18px, rgba(0,0,0,0.027) 0px 2.025px 7.85px, rgba(0,0,0,0.02) 0px 0.8px 2.93px, rgba(0,0,0,0.01) 0px 0.175px 1.04px. Title at 22px NotionInter weight 700, letter-spacing -0.25px. Body at 16px weight 400, color #615d59."
- "Build a pill badge: #f2f9ff background, #097fe8 text, 9999px radius, 4px 8px padding, 12px NotionInter weight 600, letter-spacing 0.125px."
- "Create navigation: white header. NotionInter 15px weight 600 for links, near-black text. Blue pill CTA 'Get Notion free' right-aligned (#0075de bg, white text, 4px radius)."
- "Design an alternating section layout: white sections alternate with warm white (#f6f5f4) sections. Each section has 64-80px vertical padding, max-width 1200px centered. Section heading at 48px weight 700, line-height 1.00, letter-spacing -1.5px."

## Iteration Guide

1. Always use warm neutrals -- Notion's grays have yellow-brown undertones (#f6f5f4, #31302e, #615d59, #a39e98), never blue-gray
2. Letter-spacing scales with font size: -2.125px at 64px, -1.875px at 54px, -0.625px at 26px, normal at 16px
3. Four weights: 400 (read), 500 (interact), 600 (emphasize), 700 (announce)
4. Borders are whispers: 1px solid rgba(0,0,0,0.1) -- never heavier
5. Shadows use 4-5 layers with individual opacity never exceeding 0.05
6. The warm white (#f6f5f4) section background is essential for visual rhythm
7. Pill badges (9999px) for status/tags, 4px radius for buttons and inputs
8. Notion Blue (#0075de) is the only saturated color in core UI -- use it sparingly for CTAs and links
