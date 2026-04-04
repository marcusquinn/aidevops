<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Expo — Agent Prompt Guide

## Quick Color Reference

- Primary CTA / Headlines: "Expo Black (#000000)"
- Page Background: "Cloud Gray (#f0f0f3)"
- Card Surface: "Pure White (#ffffff)"
- Body Text: "Near Black (#1c2024)"
- Secondary Text: "Slate Gray (#60646c)"
- Borders: "Border Lavender (#e0e1e6)"
- Links: "Link Cobalt (#0d74ce)"
- Tertiary Text: "Silver (#b0b4ba)"

## Example Component Prompts

- "Create a hero section on Cloud Gray (#f0f0f3) with a massive headline at 64px Inter weight 700, line-height 1.10, letter-spacing -3px. Text in Expo Black (#000000). Below, add a subtitle in Slate Gray (#60646c) at 18px. Place a black pill-shaped CTA button (9999px radius) beneath."
- "Design a feature card on Pure White (#ffffff) with a 1px solid Border Lavender (#e0e1e6) border and comfortably rounded corners (8px). Title in Near Black (#1c2024) at 20px Inter weight 600, description in Slate Gray (#60646c) at 16px. Add a whisper shadow (rgba(0,0,0,0.08) 0px 3px 6px)."
- "Build a navigation bar with Expo logo on the left, text links in Near Black (#1c2024) at 14px Inter weight 500, and a black pill CTA button on the right. Background: transparent with blur backdrop. Bottom border: 1px solid Border Lavender (#e0e1e6)."
- "Create a code block using JetBrains Mono at 14px on a Pure White surface with Border Lavender border and 8px radius. Code in Near Black, keywords in Link Cobalt (#0d74ce)."
- "Design a status badge pill (9999px radius) with a green dot and 'All Systems Operational' text in Inter 12px weight 500. Background: Pure White, border: 1px solid Input Border (#d9d9e0)."

## Iteration Guide

1. Focus on ONE component at a time
2. Reference specific color names and hex codes — "use Slate Gray (#60646c)" not "make it gray"
3. Use radius values deliberately — 6px for buttons, 8px for cards, 24px for images, 9999px for pills
4. Describe the "feel" alongside measurements — "enormous breathing room with 96px section spacing"
5. Always specify Inter and the exact weight — weight contrast IS the hierarchy
6. For shadows, specify "whisper shadow" or "standard elevation" from the elevation table
7. Keep the interface monochrome — let product content be the color
