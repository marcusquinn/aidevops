---
version: alpha
name: Agency Creative
description: Bold, expressive design system with purple-to-pink gradient axis, editorial aesthetic, asymmetric layouts, and motion as a core element
colors:
  primary: "#7c3aed"
  secondary: "#a78bfa"
  tertiary: "#ec4899"
  neutral: "#0f0f0f"
  surface: "#18181b"
  on-surface: "#f8fafc"
  error: "#f87171"
typography:
  headline-display:
    fontFamily: "'Space Grotesk', 'Plus Jakarta Sans', system-ui, sans-serif"
    fontSize: 80px
    fontWeight: 700
    lineHeight: 1.0
    letterSpacing: -0.04em
  headline-lg:
    fontFamily: "'Space Grotesk', 'Plus Jakarta Sans', system-ui, sans-serif"
    fontSize: 48px
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: -0.03em
  headline-md:
    fontFamily: "'Space Grotesk', 'Plus Jakarta Sans', system-ui, sans-serif"
    fontSize: 36px
    fontWeight: 600
    lineHeight: 1.15
    letterSpacing: -0.02em
  body-lg:
    fontFamily: "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.7
    letterSpacing: -0.006em
  body-md:
    fontFamily: "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.65
    letterSpacing: -0.006em
  body-sm:
    fontFamily: "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
  label-md:
    fontFamily: "'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 12px
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: 0.04em
rounded:
  none: 0px
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
  margin: 40px
components:
  button-primary:
    backgroundColor: "linear-gradient(135deg, {colors.primary}, {colors.tertiary})"
    textColor: "#ffffff"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    padding: 14px 28px
  button-primary-hover:
    backgroundColor: "linear-gradient(135deg, #5b21b6, #be185d)"
  button-secondary:
    backgroundColor: transparent
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.full}"
    border: "1px solid {colors.primary}"
    padding: 14px 28px
  input-default:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: 12px 16px
    border: "1px solid #27272a"
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
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

# Design System: Agency Creative

Bold, expressive design system built around a purple-to-pink gradient axis. Editorial aesthetic, asymmetric layouts, motion as a core element.

**Signature gradient:** `linear-gradient(135deg, #7c3aed, #ec4899)` | **Dark bg:** `#0f0f0f` | **Light bg:** `#ffffff`

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

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
