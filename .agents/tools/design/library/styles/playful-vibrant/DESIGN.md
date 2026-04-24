---
version: alpha
name: Playful Vibrant
description: Energetic, joyful design system for children's education apps, gaming platforms, social communities, and creative tools
colors:
  primary: "#6366f1"
  secondary: "#6b7280"
  tertiary: "#f43f5e"
  neutral: "#FAFAFA"
  surface: "#FFFFFF"
  on-surface: "#1e1b4b"
  error: "#ef4444"
typography:
  headline-display:
    fontFamily: "Nunito, 'Nunito Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 56px
    fontWeight: 800
    lineHeight: 1.1
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: "Nunito, 'Nunito Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 40px
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: -0.015em
  headline-md:
    fontFamily: "Nunito, 'Nunito Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 32px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: -0.01em
  body-lg:
    fontFamily: "Nunito, 'Nunito Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.6
  body-md:
    fontFamily: "Nunito, 'Nunito Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.6
  body-sm:
    fontFamily: "Nunito, 'Nunito Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
    letterSpacing: 0.005em
  label-md:
    fontFamily: "Nunito, 'Nunito Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 12px
    fontWeight: 600
    lineHeight: 1.4
    letterSpacing: 0.02em
rounded:
  none: 0
  sm: 8px
  md: 12px
  lg: 16px
  xl: 20px
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
    rounded: "{rounded.lg}"
    padding: 14px 28px
  button-primary-hover:
    backgroundColor: "#4f46e5"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.lg}"
    border: "2px solid {colors.primary}"
    padding: 12px 26px
  input-default:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.lg}"
    padding: 14px 18px
    border: "2px solid #E5E7EB"
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.xl}"
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

# Design System: Playful Vibrant

Energetic, joyful design system for children's education apps, gaming platforms, social communities, and creative tools. Bold indigo primary (`#6366f1`), rose accent (`#f43f5e`), rounded shapes (16-20px radii), bouncy spring animations.

## Chapters

| # | File | Spec Section |
|---|------|-------------|
| 1 | [01-overview.md](01-overview.md) | Overview |
| 2 | [02-colour-palette.md](02-colour-palette.md) | Colors |
| 3 | [03-typography.md](03-typography.md) | Typography |
| 4 | [05-layout.md](05-layout.md) | Layout |
| 5 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation & Depth |
| 6 | [05-layout.md](05-layout.md) | Shapes (Border-Radius Scale) |
| 7 | [04-components.md](04-components.md) | Components |
| 8 | [07-dos-and-donts.md](07-dos-and-donts.md) | Do's and Don'ts |
| 9 | [08-responsive.md](08-responsive.md) | Responsive Behaviour |
| 10 | [09-agent-prompts.md](09-agent-prompts.md) | Agent Prompt Guide |

## Quick Reference

**Colours:** Primary `#6366f1` · Accent `#f43f5e` · Background `#FAFAFA` · Heading text `#1e1b4b`

**Shapes:** Buttons/inputs `border-radius: 16px` · Cards `border-radius: 20px` · Pills `border-radius: 9999px`

**Animation:** Spring easing `cubic-bezier(0.34, 1.56, 0.64, 1)` · Transition `200ms`

**Typography:** Nunito (rounded sans-serif) · Headings weight 700 · Display weight 800

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
