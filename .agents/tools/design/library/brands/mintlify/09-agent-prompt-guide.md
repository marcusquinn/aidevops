<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mintlify: Agent Prompt Guide

## Quick Color Reference

- Primary CTA: Near Black (`#0d0d0d`)
- Background: Pure White (`#ffffff`)
- Heading text: Near Black (`#0d0d0d`)
- Body text: Gray 700 (`#333333`)
- Border: `rgba(0,0,0,0.05)` (5% opacity)
- Brand accent: Green (`#18E299`)
- Link hover: Brand Green (`#18E299`)
- Focus ring: Brand Green (`#18E299`)

## Example Component Prompts

- "Create a hero section on white background with atmospheric green-white gradient wash. Headline at 64px Inter weight 600, line-height 1.15, letter-spacing -1.28px, color #0d0d0d. Subtitle at 18px Inter weight 400, line-height 1.50, color #666666. Dark pill CTA (#0d0d0d, 9999px radius, 8px 24px padding) and ghost pill button (white, 1px solid rgba(0,0,0,0.08), 9999px radius)."
- "Design a card: white background, 1px solid rgba(0,0,0,0.05) border, 16px radius, 24px padding, shadow rgba(0,0,0,0.03) 0px 2px 4px. Title at 20px Inter weight 600, letter-spacing -0.2px. Body at 14px weight 400, #666666."
- "Build a pill badge: #d4fae8 background, #0fa76e text, 9999px radius, 4px 12px padding, 13px Inter weight 500, uppercase."
- "Create navigation: white sticky header with backdrop-filter blur(12px). Inter 15px weight 500 for links, #0d0d0d text. Dark pill CTA 'Get Started' right-aligned, 9999px radius. Bottom border: 1px solid rgba(0,0,0,0.05)."
- "Design a trust section showing company logos in muted gray. Grid layout with 16px radius containers, 1px border at 5% opacity. Label above: 'Loved by your favorite companies' at 13px Inter weight 500, uppercase, tracking 0.65px."

## Iteration Guide

1. Always use full-pill radius (9999px) for buttons and inputs — this is Mintlify's signature shape
2. Keep borders at 5% opacity (`rgba(0,0,0,0.05)`) — stronger borders break the airy feeling
3. Letter-spacing scales with font size: -1.28px at 64px, -0.8px at 40px, -0.24px at 24px, normal at 16px
4. Three weights only: 400 (read), 500 (interact), 600 (announce)
5. Brand green (`#18E299`) is used sparingly — CTAs and hover states only, never for decorative fills
6. Geist Mono uppercase for technical labels, Inter for everything else
7. Section padding is generous: 64px–96px on desktop, 48px on mobile
8. No gray background sections — white throughout, separation through borders and whitespace
