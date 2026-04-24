---
version: alpha
name: Agency Feminine
description: Soft, elegant design system for brands communicating warmth, refinement, and understated beauty
colors:
  primary: "#d4a5a5"
  secondary: "#7a6e65"
  tertiary: "#9caf88"
  neutral: "#fdf6ee"
  surface: "#ffffff"
  on-surface: "#3d3530"
  error: "#c97070"
typography:
  headline-display:
    fontFamily: "'Cormorant Garamond', 'Cormorant', 'Playfair Display', Georgia, serif"
    fontSize: 56px
    fontWeight: 400
    lineHeight: 1.1
    letterSpacing: -0.01em
  headline-lg:
    fontFamily: "'Cormorant Garamond', 'Cormorant', 'Playfair Display', Georgia, serif"
    fontSize: 44px
    fontWeight: 400
    lineHeight: 1.15
    letterSpacing: -0.005em
  headline-md:
    fontFamily: "'Cormorant Garamond', 'Cormorant', 'Playfair Display', Georgia, serif"
    fontSize: 36px
    fontWeight: 400
    lineHeight: 1.2
  body-lg:
    fontFamily: "'Lato', 'Source Sans 3', -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: 18px
    fontWeight: 300
    lineHeight: 1.8
    letterSpacing: 0.005em
  body-md:
    fontFamily: "'Lato', 'Source Sans 3', -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: 16px
    fontWeight: 300
    lineHeight: 1.75
    letterSpacing: 0.005em
  body-sm:
    fontFamily: "'Lato', 'Source Sans 3', -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.6
    letterSpacing: 0.005em
  label-md:
    fontFamily: "'Lato', 'Source Sans 3', -apple-system, BlinkMacSystemFont, sans-serif"
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: 0.05em
rounded:
  none: 0
  sm: 8px
  md: 12px
  lg: 16px
  xl: 24px
  full: 999px
spacing:
  unit: 8px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 32px
  xl: 64px
  gutter: 24px
  margin: 32px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "#ffffff"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 14px 32px
  button-primary-hover:
    backgroundColor: "#c79393"
  button-secondary:
    backgroundColor: transparent
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    border: "1.5px solid {colors.primary}"
    padding: 14px 32px
  input-default:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: 14px 18px
    border: "1px solid #e8ddd0"
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
    padding: 32px
---

<!--
DESIGN.md — AI-readable design system document
Format: google-labs-code/design.md v0.1.0 (format version: alpha)
Spec: https://github.com/google-labs-code/design.md/blob/main/docs/spec.md
Validate: npx @google/design.md lint DESIGN.md
-->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Agency Feminine

Soft, elegant design system for brands communicating warmth, refinement, and understated beauty. Cream background (`#fdf6ee`), dusty rose primary (`#d4a5a5`), sage green accent (`#9caf88`), Cormorant serif headings, generous whitespace.

## Chapters

| # | File | Spec Section |
|---|------|-------------|
| 1 | [01-theme.md](01-theme.md) | Overview |
| 2 | [02-colours.md](02-colours.md) | Colors |
| 3 | [03-typography.md](03-typography.md) | Typography |
| 4 | [05-layout.md](05-layout.md) | Layout |
| 5 | [06-elevation.md](06-elevation.md) | Elevation & Depth |
| 6 | [05-layout.md](05-layout.md) | Shapes (Border Radius Scale) |
| 7 | [04-components.md](04-components.md) | Components |
| 8 | [07-dos-donts.md](07-dos-donts.md) | Do's and Don'ts |
| 9 | [08-responsive.md](08-responsive.md) | Responsive Behaviour |
| 10 | [09-agent-prompts.md](09-agent-prompts.md) | Agent Prompt Guide |

## Quick Reference

**Colours:** `#d4a5a5` primary (dusty rose) · `#9caf88` accent (sage) · `#3d3530` text · `#fdf6ee` bg · `#ffffff` surface

**Type:** Cormorant Garamond (serif headings) · Lato 300 (body) · Display 56px/400 · H1 44px/400 · Body 16px/300

**Radius:** 12px default · 16px cards · 999px pill buttons

**Motion:** 400–600ms ease-in-out, fade and slide

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
