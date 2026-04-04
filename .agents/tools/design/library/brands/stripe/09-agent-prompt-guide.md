<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agent Prompt Guide

## Quick Color Reference

- Primary CTA: Stripe Purple (`#533afd`)
- CTA Hover: Purple Dark (`#4434d4`)
- Background: Pure White (`#ffffff`)
- Heading text: Deep Navy (`#061b31`)
- Body text: Slate (`#64748d`)
- Label text: Dark Slate (`#273951`)
- Border: Soft Blue (`#e5edf5`)
- Link: Stripe Purple (`#533afd`)
- Dark section: Brand Dark (`#1c1e54`)
- Success: Green (`#15be53`)
- Accent decorative: Ruby (`#ea2261`), Magenta (`#f96bee`)

## Example Component Prompts

- "Create a hero section on white background. Headline at 48px sohne-var weight 300, line-height 1.15, letter-spacing -0.96px, color #061b31, font-feature-settings 'ss01'. Subtitle at 18px weight 300, line-height 1.40, color #64748d. Purple CTA button (#533afd, 4px radius, 8px 16px padding, white text) and ghost button (transparent, 1px solid #b9b9f9, #533afd text, 4px radius)."
- "Design a card: white background, 1px solid #e5edf5 border, 6px radius. Shadow: rgba(50,50,93,0.25) 0px 30px 45px -30px, rgba(0,0,0,0.1) 0px 18px 36px -18px. Title at 22px sohne-var weight 300, letter-spacing -0.22px, color #061b31, 'ss01'. Body at 16px weight 300, #64748d."
- "Build a success badge: rgba(21,190,83,0.2) background, #108c3d text, 4px radius, 1px 6px padding, 10px sohne-var weight 300, border 1px solid rgba(21,190,83,0.4)."
- "Create navigation: white sticky header with backdrop-filter blur(12px). sohne-var 14px weight 400 for links, #061b31 text, 'ss01'. Purple CTA 'Start now' right-aligned (#533afd bg, white text, 4px radius). Nav container 6px radius."
- "Design a dark brand section: #1c1e54 background, white text. Headline 32px sohne-var weight 300, letter-spacing -0.64px, 'ss01'. Body 16px weight 300, rgba(255,255,255,0.7). Cards inside use rgba(255,255,255,0.1) border with 6px radius."

## Iteration Guide

1. Always enable `font-feature-settings: "ss01"` on sohne-var text -- this is the brand's typographic DNA
2. Weight 300 is the default; use 400 only for buttons/links/navigation
3. Shadow formula: `rgba(50,50,93,0.25) 0px Y1 B1 -S1, rgba(0,0,0,0.1) 0px Y2 B2 -S2` where Y1/B1 are larger (far shadow) and Y2/B2 are smaller (near shadow)
4. Heading color is `#061b31` (deep navy), body is `#64748d` (slate), labels are `#273951` (dark slate)
5. Border-radius stays in the 4px-8px range -- never use pill shapes or large rounding
6. Use `"tnum"` for any numbers in tables, charts, or financial displays
7. Dark sections use `#1c1e54` -- not black, not gray, but a deep branded indigo
8. SourceCodePro for code at 12px/500 with 2.00 line-height (very generous for readability)
