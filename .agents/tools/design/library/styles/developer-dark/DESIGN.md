---
version: alpha
name: Developer Dark
description: Terminal-native dark interface for developers with deep grey backgrounds, terminal-green accent, and monospace-first typography
colors:
  primary: "#4ade80"
  secondary: "#9ca3af"
  tertiary: "#fbbf24"
  neutral: "#111827"
  surface: "#1f2937"
  on-surface: "#f9fafb"
  error: "#ef4444"
typography:
  headline-display:
    fontFamily: "'JetBrains Mono', 'Fira Code', 'SF Mono', ui-monospace, monospace"
    fontSize: 36px
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: -0.5px
  headline-lg:
    fontFamily: "'JetBrains Mono', 'Fira Code', 'SF Mono', ui-monospace, monospace"
    fontSize: 28px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: -0.3px
  headline-md:
    fontFamily: "'JetBrains Mono', 'Fira Code', 'SF Mono', ui-monospace, monospace"
    fontSize: 22px
    fontWeight: 600
    lineHeight: 1.25
    letterSpacing: -0.2px
  body-md:
    fontFamily: "'Inter', -apple-system, system-ui, 'Segoe UI', sans-serif"
    fontSize: 15px
    fontWeight: 400
    lineHeight: 1.6
  body-sm:
    fontFamily: "'Inter', -apple-system, system-ui, 'Segoe UI', sans-serif"
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
  label-md:
    fontFamily: "'JetBrains Mono', 'Fira Code', 'SF Mono', ui-monospace, monospace"
    fontSize: 13px
    fontWeight: 600
    lineHeight: 1.0
    letterSpacing: 0.5px
rounded:
  none: 0
  sm: 4px
  md: 4px
  lg: 6px
  xl: 6px
  full: 9999px
spacing:
  unit: 4px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 32px
  xl: 64px
  gutter: 16px
  margin: 32px
components:
  button-primary:
    backgroundColor: "{colors.primary}"
    textColor: "{colors.neutral}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 10px 20px
  button-primary-hover:
    backgroundColor: "#22c55e"
  button-secondary:
    backgroundColor: transparent
    textColor: "{colors.on-surface}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    border: "1px solid #1f2937"
    padding: 10px 20px
  input-default:
    backgroundColor: "#0d1117"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-md}"
    rounded: "{rounded.md}"
    padding: 10px 14px
    border: "1px solid #1f2937"
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
    padding: 16px
    border: "1px solid #1f2937"
---

<!--
DESIGN.md — AI-readable design system document
Format: google-labs-code/design.md v0.1.0 (format version: alpha)
Spec: https://github.com/google-labs-code/design.md/blob/main/docs/spec.md
Validate: npx @google/design.md lint DESIGN.md
-->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Developer Dark

Terminal-native dark interface for developers. Deep grey backgrounds (`#111827`), terminal-green accent (`#4ade80`), monospace-first typography (JetBrains Mono), 4px spacing grid, border-driven depth.

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

**Colours:** `#111827` bg · `#4ade80` accent (green) · `#fbbf24` secondary (amber) · `#ef4444` error · `#f9fafb` text

**Type:** JetBrains Mono (headings/code/buttons) · Inter (body) · Display 36px/700 · Body 15px/400

**Radius:** 4px default · 6px code blocks · 9999px pills

**Spacing:** 4px base unit · compact by default

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
