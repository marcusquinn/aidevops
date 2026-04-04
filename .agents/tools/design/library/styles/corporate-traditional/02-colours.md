<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Corporate Traditional — Colour Palette & Roles

## Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#1B365D` | Headers, primary buttons, navigation background |
| Primary Light | `#2A4A7F` | Hover states, secondary elements |
| Primary Dark | `#0F2341` | Active states, footer background |

## Accent

| Role | Hex | Usage |
|------|-----|-------|
| Gold | `#B8860B` | CTAs, highlights, award badges, key links |
| Gold Light | `#D4A843` | Hover on gold elements |
| Gold Muted | `#C9B97A` | Decorative borders, subtle highlights |

## Text

| Role | Hex | Usage |
|------|-----|-------|
| Heading | `#1B365D` | All headings h1–h6 |
| Body | `#333333` | Paragraph text, descriptions |
| Secondary | `#6B7280` | Captions, metadata, timestamps |
| Inverse | `#FFFFFF` | Text on dark backgrounds |

## Surface

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FFFFFF` | Page background |
| Surface Alt | `#F5F5F0` | Alternating sections, sidebar |
| Surface Accent | `#EEF0F4` | Card backgrounds, table headers |
| Border | `#D1D5DB` | Dividers, table borders, input borders |
| Border Strong | `#9CA3AF` | Active input borders |

## Semantic

| Role | Hex | Usage |
|------|-----|-------|
| Success | `#166534` | Confirmations, positive indicators |
| Warning | `#92400E` | Caution messages |
| Error | `#991B1B` | Error states, required fields |
| Info | `#1E40AF` | Informational callouts |

## Shadows

| Role | Value | Usage |
|------|-------|-------|
| Shadow colour | `rgba(27, 54, 93, 0.08)` | All shadow definitions |
| Shadow strong | `rgba(27, 54, 93, 0.15)` | Elevated elements |

## CSS Variables

```css
:root {
  /* Primary */
  --color-primary: #1B365D;
  --color-primary-light: #2A4A7F;
  --color-primary-dark: #0F2341;

  /* Accent */
  --color-gold: #B8860B;
  --color-gold-light: #D4A843;
  --color-gold-muted: #C9B97A;

  /* Text */
  --color-text-heading: #1B365D;
  --color-text-body: #333333;
  --color-text-secondary: #6B7280;
  --color-text-inverse: #FFFFFF;

  /* Surface */
  --color-bg: #FFFFFF;
  --color-surface-alt: #F5F5F0;
  --color-surface-accent: #EEF0F4;
  --color-border: #D1D5DB;
  --color-border-strong: #9CA3AF;

  /* Semantic */
  --color-success: #166534;
  --color-warning: #92400E;
  --color-error: #991B1B;
  --color-info: #1E40AF;

  /* Shadows */
  --shadow-color: rgba(27, 54, 93, 0.08);
  --shadow-color-strong: rgba(27, 54, 93, 0.15);
}
```
