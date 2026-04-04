# Agent Prompt Guide

## Quick Color Reference

- Light bg: `#ffffff`, `#f1f2f3`
- Dark bg: `#15181e`, `#0d0e12`
- Text light: `#000000`, `#3b3d45`
- Text dark: `#efeff1`, `#d5d7db`
- Links: `#2264d6` (light), `#1060ff` (dark), `#2b89ff` (active)
- Helper text: `#656a76`
- Borders: `rgba(178, 182, 189, 0.4)`, `rgb(97, 104, 117)`
- Focus: `3px solid` product-appropriate color

## Example Component Prompts

- "Create a hero on dark background (#15181e). Headline at 82px HashiCorp Sans weight 600, line-height 1.17, kern enabled, white text. Sub-text at 20px system-ui weight 400, line-height 1.50, #d5d7db text. Two buttons: primary dark (#15181e, 5px radius, 9px 15px padding) and secondary white (#ffffff, 4px radius, 8px 12px padding)."
- "Design a product card: white background, 8px radius, dual-layer shadow at rgba(97,104,117,0.05). Title at 26px HashiCorp Sans weight 700, body at 16px system-ui weight 400 line-height 1.63."
- "Build an uppercase section label: 13px HashiCorp Sans weight 600, line-height 1.69, letter-spacing 1.3px, text-transform uppercase, #656a76 color."
- "Create a product-specific CTA button: Terraform → #7b42bc background, Vault → #ffcf25 with dark text, Waypoint → #14c6cb. All: 5px radius, 500 weight text, 16px system-ui."
- "Design a dark form: #0d0e12 input background, #efeff1 text, 1px solid rgb(97,104,117) border, 5px radius, 11px padding. Focus: 3px solid accent-color outline."

## Iteration Guide

1. Always start with the mode decision: light (white) for informational, dark (#15181e) for hero/product
2. HashiCorp Sans for headings only (17px+), system-ui for everything else
3. Shadows are at whisper level (0.05 opacity) — if visible, reduce
4. Product colors are sacred — each product owns exactly one color
5. Focus rings are always 3px solid, color-matched to product context
6. Uppercase labels are the systematic wayfinding pattern — 13px, 600, 1.3px tracking
