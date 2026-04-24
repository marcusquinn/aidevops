---
version: alpha
name: Corporate Traditional
description: Institutional authority and trustworthiness with navy blue primary and gold accent for conservative professional contexts
colors:
  primary: "#1B365D"
  secondary: "#6B7280"
  tertiary: "#B8860B"
  neutral: "#FFFFFF"
  surface: "#F5F5F0"
  on-surface: "#333333"
  error: "#991B1B"
typography:
  headline-display:
    fontFamily: "Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 48px
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: "Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 36px
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: -0.01em
  headline-md:
    fontFamily: "Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 28px
    fontWeight: 700
    lineHeight: 1.3
    letterSpacing: -0.005em
  body-lg:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.6
  body-md:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.6
  body-sm:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: 0.005em
  label-md:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 12px
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: 0.02em
rounded:
  none: 0
  sm: 2px
  md: 4px
  lg: 6px
  xl: 6px
  full: 9999px
spacing:
  unit: 8px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 32px
  xl: 64px
  gutter: 24px
  margin: 48px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "#FFFFFF"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 12px 24px
  button-primary-hover:
    backgroundColor: "#2A4A7F"
  button-secondary:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    border: "1px solid #D1D5DB"
    padding: 12px 24px
  input-default:
    backgroundColor: "#FFFFFF"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: 12px 16px
    border: "1px solid #D1D5DB"
  card:
    backgroundColor: "#FFFFFF"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.md}"
    padding: 24px
---

<!--
DESIGN.md — AI-readable design system document
Format: google-labs-code/design.md v0.1.0 (format version: alpha)
Spec: https://github.com/google-labs-code/design.md/blob/main/docs/spec.md
Validate: npx @google/design.md lint DESIGN.md
-->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Corporate Traditional

Institutional authority, trustworthiness, and time-tested professionalism. Navy blue `#1B365D` + gold `#B8860B` on white. Conservative, structured, serif headings, minimal animation.

## Chapters

| # | File | Spec Section |
|---|------|-------------|
| 1 | [01-theme.md](01-theme.md) | Overview |
| 2 | [02-colours.md](02-colours.md) | Colors |
| 3 | [03-typography.md](03-typography.md) | Typography |
| 4 | [05-layout.md](05-layout.md) | Layout |
| 5 | [06-elevation.md](06-elevation.md) | Elevation & Depth |
| 6 | [05-layout.md](05-layout.md) | Shapes (Border-Radius Scale) |
| 7 | [04-components.md](04-components.md) | Components |
| 8 | [07-dos-and-donts.md](07-dos-and-donts.md) | Do's and Don'ts |
| 9 | [08-responsive.md](08-responsive.md) | Responsive Behaviour |
| 10 | [09-agent-prompts.md](09-agent-prompts.md) | Agent Prompt Guide |

## Quick Reference

- **Primary:** `#1B365D` (navy) · `#2A4A7F` (hover) · `#0F2341` (active/footer)
- **Accent:** `#B8860B` (gold) · `#D4A843` (gold hover)
- **Text:** `#333333` (body) · `#1B365D` (headings) · `#6B7280` (secondary)
- **Surface:** `#FFFFFF` (bg) · `#F5F5F0` (alt) · `#D1D5DB` (border)
- **Headings:** `Georgia, serif` · **Body:** `system-ui, sans-serif`
- **Grid:** 12-col, 1200px max, 24px gutter · **Animation:** 200ms ease, opacity/colour only

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
