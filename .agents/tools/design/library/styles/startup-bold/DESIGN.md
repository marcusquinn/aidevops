---
version: alpha
name: Startup Bold
description: Energetic, high-confidence design system for products that need to capture attention fast and convert
colors:
  primary: "#4f46e5"
  secondary: "#6b7280"
  tertiary: "#10b981"
  neutral: "#ffffff"
  surface: "#f9fafb"
  on-surface: "#111827"
  error: "#ef4444"
typography:
  headline-display:
    fontFamily: "'Plus Jakarta Sans', 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 64px
    fontWeight: 800
    lineHeight: 1.05
    letterSpacing: -0.035em
  headline-lg:
    fontFamily: "'Plus Jakarta Sans', 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 48px
    fontWeight: 700
    lineHeight: 1.1
    letterSpacing: -0.03em
  headline-md:
    fontFamily: "'Plus Jakarta Sans', 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 36px
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: -0.025em
  body-lg:
    fontFamily: "'Plus Jakarta Sans', 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.65
    letterSpacing: -0.006em
  body-md:
    fontFamily: "'Plus Jakarta Sans', 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.6
    letterSpacing: -0.006em
  body-sm:
    fontFamily: "'Plus Jakarta Sans', 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 14px
    fontWeight: 400
    lineHeight: 1.5
  label-md:
    fontFamily: "'Plus Jakarta Sans', 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif"
    fontSize: 13px
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: 0.02em
rounded:
  none: 0
  sm: 6px
  md: 12px
  lg: 16px
  xl: 24px
  full: 9999px
spacing:
  unit: 4px
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
    rounded: "{rounded.md}"
    padding: 14px 28px
  button-primary-hover:
    backgroundColor: "#4338ca"
  button-secondary:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    border: "1px solid #e5e7eb"
    padding: 14px 28px
  input-default:
    backgroundColor: "{colors.neutral}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: 12px 16px
    border: "1px solid #e5e7eb"
  card:
    backgroundColor: "{colors.neutral}"
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

# Design System: Startup Bold

Energetic, high-confidence design system for products that need to capture attention fast and convert. Indigo primary (`#4f46e5`) + emerald accent (`#10b981`), bold rounded components, structured grid.

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

**Colours:** `#4f46e5` primary · `#10b981` accent · `#111827` text · `#ffffff` bg · `#f9fafb` surface-1

**Type:** Plus Jakarta Sans · Display 64px/800 · H1 48px/700 · Body 16px/400

**Radius:** 12px default · 16px cards · 6px badges

**Motion:** 200-300ms ease-out

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
