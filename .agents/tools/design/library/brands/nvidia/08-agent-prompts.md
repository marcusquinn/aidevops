# Design System: NVIDIA — Agent Prompt Guide

## Quick Color Reference

- Primary accent: NVIDIA Green (`#76b900`)
- Background dark: True Black (`#000000`)
- Background light: Pure White (`#ffffff`)
- Heading text (dark bg): White (`#ffffff`)
- Heading text (light bg): Black (`#000000`)
- Body text (light bg): Black (`#000000`) or Near Black (`#1a1a1a`)
- Body text (dark bg): White (`#ffffff`) or Gray 300 (`#a7a7a7`)
- Link hover: Blue (`#3860be`)
- Border accent: `2px solid #76b900`
- Button hover: Teal (`#1eaedb`)

## Example Component Prompts

- "Create a hero section on black background. Headline at 36px NVIDIA-EMEA weight 700, line-height 1.25, color #ffffff. Subtitle at 18px weight 400, line-height 1.67, color #a7a7a7. CTA button with transparent background, 2px solid #76b900 border, 2px radius, 11px 13px padding, text #ffffff. Hover: background #1eaedb, text white."
- "Design a product card: white background, 2px border-radius, box-shadow rgba(0,0,0,0.3) 0px 0px 5px. Title at 20px NVIDIA-EMEA weight 700, line-height 1.25, color #000000. Body at 15px weight 400, line-height 1.67, color #757575. Green underline accent on title: border-bottom 2px solid #76b900."
- "Build a navigation bar: #000000 background, sticky top. NVIDIA logo left-aligned. Links at 14px NVIDIA-EMEA weight 700 uppercase, color #ffffff. Hover: color #3860be. Green-bordered CTA button right-aligned."
- "Create a dark feature section: #000000 background. Section label at 14px weight 700 uppercase, color #76b900. Heading at 24px weight 700, color #ffffff. Description at 16px weight 400, color #a7a7a7. Three product cards in a row with 20px gap."
- "Design a footer: #000000 background. Multi-column layout with link groups. Links at 14px weight 400, color #a7a7a7. Hover: color #76b900. Bottom bar with legal text at 12px, color #757575."

## Iteration Guide

1. Always use `#76b900` as accent, never as a background fill -- it's a signal color for borders, underlines, and highlights
2. Buttons are transparent with green borders by default -- filled backgrounds appear only on hover/active states
3. Weight 700 is the dominant voice for all interactive and heading elements; 400 is only for body paragraphs
4. Border radius is 2px for everything -- this sharp, minimal rounding is core to the industrial aesthetic
5. Dark sections use white text; light sections use black text -- green accent works identically on both
6. Link hover is always `#3860be` (blue) regardless of the link's default color
7. Line-height 1.25 for headings, 1.50-1.67 for body text -- maintain this contrast for visual hierarchy
8. Navigation uses uppercase 14px bold -- this hardware-label typography is part of the brand voice
