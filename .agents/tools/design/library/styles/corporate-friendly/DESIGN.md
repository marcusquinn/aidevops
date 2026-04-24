---
version: alpha
name: Corporate Friendly
description: Warm, approachable, professional design system with blue primary and orange accent for customer-facing services
colors:
  primary: "#3b82f6"
  secondary: "#6b7280"
  tertiary: "#f97316"
  neutral: "#FFFFFF"
  surface: "#F9FAFB"
  on-surface: "#111827"
  error: "#ef4444"
typography:
  headline-display:
    fontFamily: "'DM Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 48px
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: "'DM Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 36px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: -0.015em
  headline-md:
    fontFamily: "'DM Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 28px
    fontWeight: 600
    lineHeight: 1.3
    letterSpacing: -0.01em
  body-lg:
    fontFamily: "'DM Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.65
  body-md:
    fontFamily: "'DM Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.65
  body-sm:
    fontFamily: "'DM Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.55
    letterSpacing: 0.005em
  label-md:
    fontFamily: "'DM Sans', system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 12px
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: 0.015em
rounded:
  none: 0
  sm: 6px
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
  margin: 32px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "#FFFFFF"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 12px 24px
  button-primary-hover:
    backgroundColor: "#2563eb"
  button-secondary:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    border: "1px solid #E5E7EB"
    padding: 12px 24px
  input-default:
    backgroundColor: "#FFFFFF"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: 12px 16px
    border: "1px solid #E5E7EB"
  card:
    backgroundColor: "#FFFFFF"
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

# Design System: Corporate Friendly

Warm, approachable, professional. Blue `#3b82f6` primary, orange `#f97316` accent. Light-mode-first. Rounded corners, generous whitespace, gentle animations.

**Use cases:** Healthcare portals, educational platforms, community SaaS, customer-facing services.

## Chapters

| # | File | Spec Section |
|---|------|-------------|
| 1 | [01-theme-overview.md](01-theme-overview.md) | Overview |
| 2 | [02-colour-palette.md](02-colour-palette.md) | Colors |
| 3 | [03-typography.md](03-typography.md) | Typography |
| 4 | [05-layout.md](05-layout.md) | Layout |
| 5 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation & Depth |
| 6 | [05-layout.md](05-layout.md) | Shapes (Border-Radius Scale) |
| 7 | [04-components.md](04-components.md) | Components |
| 8 | [07-dos-and-donts.md](07-dos-and-donts.md) | Do's and Don'ts |
| 9 | [08-responsive.md](08-responsive.md) | Responsive Behaviour |
| 10 | [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Agent Prompt Guide |

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
