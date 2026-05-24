<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

---
version: alpha
name: "Mellow Yellow playful"
description: "Preserved warm rounded report preset formerly used by exsqueezeme."
colors:
  background: "#FFF7ED"
  surface: "#FFFFFF"
  on-surface: "#231A10"
  muted: "#6B5A45"
  outline: "#F3D8B7"
  primary: "#C2410C"
  primary-container: "#FFEDD5"
  code-background: "#FFF7ED"
  code-on-background: "#231A10"
  code-accent: "#C2410C"
typography:
  headline-display:
    fontFamily: 'Inter, system-ui, sans-serif'
    fontSize: 64px
    fontWeight: 650
    lineHeight: 1.05
    letterSpacing: -0.03em
  headline-md:
    fontFamily: 'Inter, system-ui, sans-serif'
    fontSize: 32px
    fontWeight: 650
    lineHeight: 1.15
  body-md:
    fontFamily: 'Inter, system-ui, sans-serif'
    fontSize: 16px
    fontWeight: 400
    lineHeight: 1.62
  code-md:
    fontFamily: '"IBM Plex Mono", Consolas, monospace'
    fontSize: 13px
    fontWeight: 400
    lineHeight: 1.5
rounded:
  md: 26px
  lg: 26px
spacing:
  md: 16px
  lg: 24px
  xl: 32px
components:
  report-card:
    backgroundColor: "{colors.surface}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
    borderWidth: 1
  evidence-badge:
    backgroundColor: "{colors.primary-container}"
    textColor: "{colors.on-surface}"
    rounded: "{rounded.lg}"
---

# Design System: Mellow Yellow playful

Warm rounded app-report energy preserved from the previous ExSqueezeMe-inspired preset. Use this when the older mellow cream/orange report output is desired independently of the current black/orange ExSqueezeMe branding.

## Quick Reference

- **Accent**: `#C2410C` with supporting container `#FFEDD5`
- **Background/surface**: `#FFF7ED` / `#FFFFFF`
- **Text**: `#231A10` primary, `#6B5A45` secondary
- **Heading font**: Inter, system-ui, sans-serif
- **Body font**: Inter, system-ui, sans-serif
- **Code font**: "IBM Plex Mono", Consolas, monospace
- **Radius**: 26px
- **Export rule**: one `report.html`; A4, Letter, and 16:9 slides are PDF profiles only.
