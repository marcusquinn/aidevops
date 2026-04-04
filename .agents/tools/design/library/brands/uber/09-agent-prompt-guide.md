# Uber Design: Agent Prompt Guide

## Quick Color Reference

- Primary Button: "Uber Black (#000000)"
- Page Background: "Pure White (#ffffff)"
- Button Text (on black): "Pure White (#ffffff)"
- Button Text (on white): "Uber Black (#000000)"
- Secondary Text: "Body Gray (#4b4b4b)"
- Tertiary Text: "Muted Gray (#afafaf)"
- Chip Background: "Chip Gray (#efefef)"
- Hover State: "Hover Gray (#e2e2e2)"
- Card Shadow: "rgba(0,0,0,0.12) 0px 4px 16px"
- Footer Background: "Uber Black (#000000)"

## Example Component Prompts

- "Create a hero section on Pure White (#ffffff) with a headline at 52px UberMove Bold (700), line-height 1.23. Use Uber Black (#000000) text. Add a subtitle in Body Gray (#4b4b4b) at 16px UberMoveText weight 400 with 1.50 line-height. Place an Uber Black (#000000) pill CTA button with Pure White text, 999px radius, padding 10px 12px."
- "Design a category navigation bar with horizontal pill buttons. Each pill: Chip Gray (#efefef) background, Uber Black (#000000) text, 14px 16px padding, 999px border-radius. Active pill inverts to Uber Black background with Pure White text. Use UberMoveText at 14px weight 500."
- "Build a feature card on Pure White (#ffffff) with 8px border-radius and shadow rgba(0,0,0,0.12) 0px 4px 16px. Title in UberMove at 24px weight 700, description in Body Gray (#4b4b4b) at 16px UberMoveText. Add a black pill CTA button at the bottom."
- "Create a dark footer on Uber Black (#000000) with Pure White (#ffffff) heading text in UberMove at 20px weight 700. Footer links in Muted Gray (#afafaf) at 14px UberMoveText. Links hover to Pure White. Multi-column grid layout."
- "Design a floating action button with Pure White (#ffffff) background, 999px radius, 14px padding, and shadow rgba(0,0,0,0.16) 0px 2px 8px. Hover shifts background to #f3f3f3. Use for scroll-to-top or map controls."

## Iteration Guide

1. Focus on ONE component at a time
2. Reference the strict black/white palette — "use Uber Black (#000000)" not "make it dark"
3. Always specify 999px radius for buttons and pills — this is non-negotiable for the Uber identity
4. Describe the font family explicitly — "UberMove Bold for the heading, UberMoveText Medium for the label"
5. For shadows, use "whisper shadow (rgba(0,0,0,0.12) 0px 4px 16px)" — never heavy drop shadows
6. Keep layouts compact and information-dense — Uber is efficient, not airy
7. Illustrations should be warm and human — describe "stylized people in warm tones" not abstract shapes
8. Pair black CTAs with white secondaries for balanced dual-action layouts
