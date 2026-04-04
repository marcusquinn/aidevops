# Design System: Composio — Agent Prompt Guide

## Quick Color Reference

- Primary CTA: "Pure White (#ffffff)"
- Page Background: "Void Black (#0f0f0f)"
- Brand Accent: "Composio Cobalt (#0007cd)"
- Glow Accent: "Electric Cyan (#00ffff)"
- Heading Text: "Pure White (#ffffff)"
- Body Text: "Ghost White (rgba(255,255,255,0.6))"
- Card Border: "Border Mist 10 (rgba(255,255,255,0.10))"
- Button Border: "Signal Blue (#0089ff)"

## Example Component Prompts

- "Create a feature card with a near-black background (#000000), barely visible white border at 10% opacity, subtly rounded corners (4px), and a hard-offset shadow (4px right, 4px down, 15% black). Use Pure White for the title in abcDiatype at 24px weight 500, and Ghost White (60% opacity) for the description at 16px."
- "Design a primary CTA button with a solid white background, near-black text, comfortable padding (8px vertical, 24px horizontal), and subtly rounded corners. Place it next to a secondary button with transparent background, Signal Blue border, and matching padding."
- "Build a hero section on Void Black (#0f0f0f) with a massive heading at 64px, line-height 0.87, in abcDiatype. Center the text. Add a subtle blue-to-black gradient glow behind the content. Include a white CTA button and a cyan-accented secondary button below."
- "Create a code snippet display using JetBrains Mono at 14px with -0.28px letter-spacing on a black background. Add a Border Mist 10 border (rgba(255,255,255,0.10)) and 4px radius. Show syntax-highlighted content with white and cyan text."
- "Design a navigation bar on Void Black with the Composio wordmark in white on the left, 4-5 nav links in white abcDiatype at 16px, and a white-fill CTA button on the right. Add a Border Mist 06 bottom border."

## Iteration Guide

When refining existing screens generated with this design system:
1. Focus on ONE component at a time
2. Reference specific color names and hex codes from this document — "use Ghost White (rgba(255,255,255,0.6))" not "make it lighter"
3. Use natural language descriptions — "make the border barely visible" = Border Mist 04-06
4. Describe the desired "feel" alongside specific measurements — "compressed and authoritative heading at 48px with line-height 1.0"
5. For glow effects, specify "Electric Cyan at 12% opacity as a radial gradient behind the element"
6. Always specify which font — abcDiatype for marketing, JetBrains Mono for technical/code content
