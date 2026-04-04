<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Sanity — Agent Prompt Guide

## Quick Color Reference

```css
Background:      #0b0b0b (near-black canvas)
Surface:         #212121 (elevated cards/containers)
Border:          #353535 (visible) / #212121 (subtle)
Text Primary:    #ffffff (white on dark)
Text Secondary:  #b9b9b9 (silver on dark)
Text Tertiary:   #797979 (medium gray)
CTA:             #f36458 (coral-red)
Interactive:     #0052ef (electric blue, all hovers)
Success:         #19d600 (green, sRGB fallback)
Error:           #dd0000 (pure red)
Light Surface:   #ededed / #ffffff (inverted sections)
```

## Example Prompts

**Landing page section:**
"Create a feature section with a near-black (#0b0b0b) background. Use a 48px heading in Inter with -1.68px letter-spacing, white text. Below it, 16px body text in #b9b9b9 with 1.50 line-height. Include a coral-red (#f36458) pill button with white text and a secondary dark (#0b0b0b) pill button with #b9b9b9 text. Both buttons hover to #0052ef blue."

**Card grid:**
"Build a 3-column card grid on a #0b0b0b background. Each card has a #212121 surface, 1px solid #353535 border, 6px border-radius, and 24px padding. Card titles are 24px white with -0.24px letter-spacing. Body text is 13px #b9b9b9. Add a 13px IBM Plex Mono uppercase tag in #797979 at the top of each card."

**Form section:**
"Design a contact form on a #0b0b0b background. Inputs have #0b0b0b background, 1px solid #212121 border, 3px border-radius, 8px 12px padding, and #b9b9b9 placeholder text. Focus state shows a 2px blue (#0052ef) ring. Submit button is a full-width coral-red (#f36458) pill. Include a 13px #797979 helper text below each field."

**Navigation bar:**
"Create a sticky top navigation on #0b0b0b with backdrop blur. Left: brand text in 15px white. Center/right: nav links in 16px #b9b9b9 that hover to blue. Far right: a coral-red (#f36458) pill CTA button. Bottom border: 1px solid #212121."

## Iteration Guide

1. **Start dark**: Begin with `#0b0b0b` background, `#ffffff` primary text, `#b9b9b9` secondary text
2. **Add structure**: Use `#212121` surfaces and `#353535` borders for containment -- no shadows
3. **Apply typography**: Inter (or Space Grotesk) with tight letter-spacing on headings, 1.50 line-height on body
4. **Color punctuation**: Add `#f36458` for CTAs and `#0052ef` for all hover/interactive states
5. **Refine spacing**: 8px base unit, 24-32px within sections, 64-120px between sections
6. **Technical details**: Add IBM Plex Mono uppercase labels for tags and metadata
7. **Polish**: Ensure all interactive elements hover to `#0052ef`, all buttons are pills or subtle 5px radius, borders are hairline (1px)
