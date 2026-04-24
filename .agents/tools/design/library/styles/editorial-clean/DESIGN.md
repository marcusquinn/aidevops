---
version: alpha
name: Editorial Clean
description: Reading-first editorial design system with warm off-white backgrounds, near-black ink, serif/sans-serif pairing, and 680px content column
colors:
  primary: "#1a1a1a"
  secondary: "#666666"
  tertiary: "#4a6fa5"
  neutral: "#FAF8F5"
  surface: "#FFFFFF"
  on-surface: "#2d2d2d"
  error: "#c0392b"
typography:
  headline-display:
    fontFamily: "'Playfair Display', Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 52px
    fontWeight: 700
    lineHeight: 1.15
    letterSpacing: -0.02em
  headline-lg:
    fontFamily: "'Playfair Display', Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 40px
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: -0.015em
  headline-md:
    fontFamily: "'Playfair Display', Georgia, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 30px
    fontWeight: 700
    lineHeight: 1.25
    letterSpacing: -0.01em
  body-lg:
    fontFamily: "'Source Sans 3', 'Source Sans Pro', system-ui, -apple-system, 'Segoe UI', sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.7
  body-md:
    fontFamily: "'Source Sans 3', 'Source Sans Pro', system-ui, -apple-system, 'Segoe UI', sans-serif"
    fontSize: 18px
    fontWeight: 400
    lineHeight: 1.7
  body-sm:
    fontFamily: "'Source Sans 3', 'Source Sans Pro', system-ui, -apple-system, 'Segoe UI', sans-serif"
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.6
  label-md:
    fontFamily: "'Source Sans 3', 'Source Sans Pro', system-ui, -apple-system, 'Segoe UI', sans-serif"
    fontSize: 14px
    fontWeight: 500
    lineHeight: 1.4
    letterSpacing: 0.03em
rounded:
  none: 0
  sm: 2px
  md: 4px
  lg: 8px
  xl: 8px
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
    textColor: "{colors.neutral}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    padding: 12px 24px
  button-primary-hover:
    backgroundColor: "#333333"
  button-secondary:
    backgroundColor: transparent
    textColor: "{colors.primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.md}"
    border: "1px solid #E8E4DF"
    padding: 12px 24px
  input-default:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    typography: "{typography.body-sm}"
    rounded: "{rounded.md}"
    padding: 12px 16px
    border: "1px solid #E8E4DF"
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

# Design System: Editorial Clean

A reading-first editorial design system. Warm off-white backgrounds, near-black ink, serif/sans-serif pairing, 680px content column. Calm, focused, literary.

## Chapters

| # | File | Spec Section |
|---|------|-------------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Overview |
| 2 | [02-colour-palette.md](02-colour-palette.md) | Colors |
| 3 | [03-typography.md](03-typography.md) | Typography |
| 4 | [05-layout.md](05-layout.md) | Layout |
| 5 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation & Depth |
| 6 | [05-layout.md](05-layout.md) | Shapes (Border-Radius Scale) |
| 7 | [04-components.md](04-components.md) | Components |
| 8 | [07-dos-and-donts.md](07-dos-and-donts.md) | Do's and Don'ts |
| 9 | [08-responsive.md](08-responsive.md) | Responsive Behaviour |
| 10 | [09-agent-prompt-guide.md](09-agent-prompt-guide.md) | Agent Prompt Guide |

## Quick Reference

**Colours:** Background `#FAF8F5` · Body text `#2d2d2d` · Headings `#1a1a1a` · Link `#4a6fa5` · Border `#E8E4DF`

**Typography:** Headings: Playfair Display (serif) · Body: Source Sans 3 (sans-serif) · Code: JetBrains Mono

**Layout:** Content column 680px · Body 18px/1.7 · Paragraph spacing 1.5em

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md spec: https://github.com/google-labs-code/design.md
-->
