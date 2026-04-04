<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Design: Agent Prompt Guide

## Quick Color Reference

- Primary CTA: IBM Blue 60 (`#0f62fe`)
- Background: White (`#ffffff`)
- Heading text: Gray 100 (`#161616`)
- Body text: Gray 100 (`#161616`)
- Secondary text: Gray 70 (`#525252`)
- Surface/Card: Gray 10 (`#f4f4f4`)
- Border: Gray 30 (`#c6c6c6`)
- Link: Blue 60 (`#0f62fe`)
- Link hover: Blue 70 (`#0043ce`)
- Focus ring: Blue 60 (`#0f62fe`)
- Error: Red 60 (`#da1e28`)
- Success: Green 50 (`#24a148`)

## Example Component Prompts

- "Create a hero section on white background. Headline at 60px IBM Plex Sans weight 300, line-height 1.17, color #161616. Subtitle at 16px weight 400, line-height 1.50, color #525252, max-width 640px. Blue CTA button (#0f62fe background, #ffffff text, 0px border-radius, 48px height, 14px 63px 14px 15px padding)."
- "Design a card tile: #f4f4f4 background, 0px border-radius, 16px padding. Title at 20px IBM Plex Sans weight 600, line-height 1.40, color #161616. Body at 14px weight 400, letter-spacing 0.16px, line-height 1.29, color #525252. Hover: background shifts to #e8e8e8."
- "Build a form field: #f4f4f4 background, 0px border-radius, 40px height, 16px horizontal padding. Label above at 12px weight 400, letter-spacing 0.32px, color #525252. Bottom-border: 2px solid transparent default, 2px solid #0f62fe on focus. Placeholder: #6f6f6f."
- "Create a dark navigation bar: #161616 background, 48px height. IBM logo white left-aligned. Links at 14px IBM Plex Sans weight 400, color #c6c6c6. Hover: #ffffff text. Active: #ffffff with 2px bottom border."
- "Build a tag component: Blue 10 (#edf5ff) background, Blue 60 (#0f62fe) text, 4px 8px padding, 24px border-radius, 12px IBM Plex Sans weight 400."

## Iteration Guide

1. Always use 0px border-radius on buttons, inputs, and cards — this is non-negotiable in Carbon
2. Letter-spacing only at small sizes: 0.16px at 14px, 0.32px at 12px — never on display text
3. Three weights: 300 (display), 400 (body), 600 (emphasis) — no bold
4. Blue 60 is the only accent color — do not introduce secondary accent hues
5. Depth comes from background-color layering (white → #f4f4f4 → #e0e0e0), not shadows
6. Inputs have bottom-border only, never fully boxed
7. Use `--cds-` prefix for token naming to stay Carbon-compatible
8. 48px is the universal interactive element height
