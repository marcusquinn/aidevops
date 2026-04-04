<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoltAgent Design System: Agent Prompt Guide

## Quick Color Reference

- Brand Accent: "Emerald Signal Green (#00d992)"
- Button Text: "VoltAgent Mint (#2fd6a1)"
- Page Background: "Abyss Black (#050507)"
- Card Surface: "Carbon Surface (#101010)"
- Border / Containment: "Warm Charcoal (#3d3a39)"
- Primary Text: "Snow White (#f2f2f2)"
- Secondary Text: "Warm Parchment (#b8b3b0)"
- Tertiary Text: "Steel Slate (#8b949e)"

## Example Component Prompts

- "Create a feature card on Carbon Surface (#101010) with a 1px solid Warm Charcoal (#3d3a39) border, comfortably rounded corners (8px). Use Snow White (#f2f2f2) for the title in system-ui at 24px weight 700, and Warm Parchment (#b8b3b0) for the description in Inter at 16px. Add a subtle Warm Ambient shadow (rgba(92, 88, 85, 0.2) 0px 0px 15px)."
- "Design a ghost button with transparent background, Snow White (#f2f2f2) text in Inter at 16px, a 1px solid Warm Charcoal (#3d3a39) border, and subtly rounded corners (6px). Padding: 12px vertical, 16px horizontal. On hover, background shifts to rgba(0, 0, 0, 0.2)."
- "Build a hero section on Abyss Black (#050507) with a massive heading at 60px system-ui, line-height 1.0, letter-spacing -0.65px. The word 'Platform' should be colored in Emerald Signal Green (#00d992). Below the heading, place a code block showing 'npm create voltagent-app@latest' in SFMono-Regular at 14px on Carbon Surface (#101010) with a copy button."
- "Create a highlighted feature card using a 2px solid Emerald Signal Green (#00d992) border instead of the standard Warm Charcoal. Keep Carbon Surface background, comfortably rounded corners (8px), and include a code snippet on the left with feature description text on the right."
- "Design a navigation bar on Abyss Black (#050507) with the VoltAgent logo (bolt icon with animated green glow) on the left, nav links in Inter at 14px weight 500 in Snow White, and a green CTA button (Carbon Surface bg, VoltAgent Mint text) on the right. Add a 1px solid Warm Charcoal bottom border."

## Iteration Guide

When refining existing screens generated with this design system:
1. Focus on ONE component at a time
2. Reference specific color names and hex codes — "use Warm Parchment (#b8b3b0)" not "make it lighter"
3. Use border treatment to communicate elevation: "change the border to 2px solid Emerald Signal Green (#00d992)" for emphasis
4. Describe the desired "feel" alongside measurements — "compressed and authoritative heading at 36px with line-height 1.11 and -0.9px letter-spacing"
5. For glow effects, specify "Emerald Signal Green (#00d992) as a drop-shadow with 2–8px blur radius"
6. Always specify which font — system-ui for headings, Inter for body/UI, SFMono-Regular for code
7. Keep animations slow and subtle — marquee scrolls at 25–80s, glow pulses gently
