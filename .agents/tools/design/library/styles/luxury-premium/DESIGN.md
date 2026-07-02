---
version: alpha
name: Luxury Premium
description: Exclusive, cinematic design system for luxury automotive, high-end real estate, premium hospitality, fine jewellery, and couture fashion
colors:
  primary: "#FFFFFF"
  secondary: "rgba(255, 255, 255, 0.5)"
  tertiary: "#c9a96e"
  neutral: "#000000"
  surface: "#0a0a0a"
  on-surface: "rgba(255, 255, 255, 0.75)"
  error: "#f87171"
typography:
  headline-display:
    fontFamily: "'Cormorant Garamond', Garamond, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 80px
    fontWeight: 300
    lineHeight: 1.05
    letterSpacing: 0.02em
  headline-lg:
    fontFamily: "'Cormorant Garamond', Garamond, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 56px
    fontWeight: 300
    lineHeight: 1.1
    letterSpacing: 0.015em
  headline-md:
    fontFamily: "'Cormorant Garamond', Garamond, 'Times New Roman', 'Noto Serif', serif"
    fontSize: 40px
    fontWeight: 300
    lineHeight: 1.15
    letterSpacing: 0.01em
  body-lg:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 15px
    fontWeight: 300
    lineHeight: 1.7
    letterSpacing: 0.02em
  body-md:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 15px
    fontWeight: 300
    lineHeight: 1.7
    letterSpacing: 0.02em
  body-sm:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 13px
    fontWeight: 300
    lineHeight: 1.6
    letterSpacing: 0.03em
  label-md:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 11px
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: 0.1em
  label-sm:
    fontFamily: "system-ui, -apple-system, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif"
    fontSize: 11px
    fontWeight: 400
    lineHeight: 1.4
    letterSpacing: 0.1em
rounded:
  none: 0px
  sm: 2px
  md: 0px
  lg: 0px
  xl: 0px
  full: 9999px
spacing:
  unit: 8px
  xs: 4px
  sm: 8px
  md: 16px
  lg: 32px
  xl: 80px
  gutter: 32px
  margin: 64px
components:
  button-primary:
    backgroundColor: "{colors.tertiary}"
    textColor: "{colors.neutral}"
    typography: "{typography.label-md}"
    rounded: "{rounded.none}"
    padding: 16px 48px
  button-primary-hover:
    backgroundColor: "#d4b87a"
  button-secondary:
    backgroundColor: transparent
    textColor: "{colors.primary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.none}"
    border: "1px solid rgba(255, 255, 255, 0.3)"
    padding: 16px 48px
  input-default:
    backgroundColor: "#111111"
    textColor: "{colors.primary}"
    typography: "{typography.body-md}"
    rounded: "{rounded.none}"
    padding: 14px 16px
    border: "1px solid rgba(255, 255, 255, 0.1)"
  card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.none}"
    padding: 32px
    border: "1px solid rgba(255, 255, 255, 0.06)"
---

<!--
DESIGN.md — AI-readable design system document
Format: google-labs-code/design.md v0.1.0 (format version: alpha)
Spec: https://github.com/google-labs-code/design.md/blob/main/docs/spec.md
Validate: npx @google/design.md lint DESIGN.md
-->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->


# Design System: Luxury Premium

This DESIGN.md file is the slim entry point for the Luxury Premium reference corpus. The complete guidance is split into chapter files to keep the always-read index short while preserving the full design system content.

## Chapter Index

| Chapter | Contents | Use when |
|---------|----------|----------|
| [01-foundations.md](01-foundations.md) | Overview, colour system, typography hierarchy and principles | Establishing the brand mood, palette, or text system |
| [02-layout-and-form.md](02-layout-and-form.md) | Spacing, grid, whitespace, elevation, depth, and shape language | Designing page structure, spatial rhythm, or visual depth |
| [03-components.md](03-components.md) | Buttons, inputs, links, cards, and navigation CSS patterns | Implementing interface components |
| [04-usage-guidance.md](04-usage-guidance.md) | Do/don't rules, responsive behaviour, quick colour reference, ready-to-use prompts | Checking usage constraints, mobile rules, or prompt examples |

## Quick Profile

- **Mood:** exclusive, cinematic, restrained, aspirational
- **Backgrounds:** black `#000000` and near-black `#0a0a0a`
- **Accent:** champagne gold `#c9a96e` for CTAs and key interactive elements only
- **Typography:** light serif headings; small, light sans-serif body copy
- **Geometry:** sharp architectural edges; default radius `0px`
- **Density:** very low; blackspace dominates the viewport
- **Motion:** slow cinematic transitions, usually `400-600ms`
- **Imagery:** full-bleed, art-directed, high-contrast photography

## Load Order

1. Read this file first for tokens, frontmatter, and chapter routing.
2. Load [01-foundations.md](01-foundations.md) for colour and typography decisions.
3. Load [02-layout-and-form.md](02-layout-and-form.md) before composing screens or spacing systems.
4. Load [03-components.md](03-components.md) when implementing controls or navigation.
5. Load [04-usage-guidance.md](04-usage-guidance.md) for validation, responsive rules, and reusable prompts.

## Preservation Notes

- The Google Labs DESIGN.md frontmatter remains in this entry point.
- All original prose, tables, CSS examples, prompt examples, URLs, and aidevops-specific extension notes moved into the chapter files above.
- Use chapter-relative links rather than line-number references; line numbers drift after future edits.
