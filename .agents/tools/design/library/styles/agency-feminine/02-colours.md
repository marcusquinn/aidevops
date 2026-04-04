<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Agency Feminine — Colour Palette & Roles

## Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#d4a5a5` | CTAs, active accents, key links |
| Primary Hover | `#c79393` | Hover state |
| Primary Light | `#e8cece` | Soft backgrounds, badges, tag fills |
| Primary Muted | `#f5ebe7` | Tinted section backgrounds |

## Accent

| Role | Hex | Usage |
|------|-----|-------|
| Accent | `#9caf88` | Secondary actions, tags, nature/wellness cues |
| Accent Hover | `#8a9d76` | Hover state |
| Accent Light | `#c5d4b8` | Soft accent backgrounds |
| Tertiary | `#c8a87e` | Gold/honey — sparingly for premium callouts |

## Text

| Role | Hex | Usage |
|------|-----|-------|
| Text Primary | `#3d3530` | Headings, body — warm near-black |
| Text Secondary | `#7a6e65` | Descriptions, captions |
| Text Tertiary | `#b0a59c` | Placeholders, disabled text, timestamps |
| Text Inverse | `#fdf6ee` | Text on dark/coloured backgrounds |
| Text Link | `#b07878` | Link colour, rose-toned |

## Surface

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#fdf6ee` | Page background, warm cream |
| Surface 1 | `#ffffff` | Cards, elevated content areas |
| Surface 2 | `#f8f0e5` | Alternating sections, subtle differentiation |
| Surface 3 | `#f0e6d8` | Active states, hover backgrounds |
| Border Default | `#e8ddd0` | Card borders, dividers |
| Border Subtle | `#f0e6d8` | Inner dividers, delicate separators |
| Border Focus | `#d4a5a5` | Focus rings, active borders |

## Semantic

| Role | Hex | Usage |
|------|-----|-------|
| Success | `#9caf88` | Confirmations, completed (uses accent) |
| Success Background | `#f0f5ec` | Success message backgrounds |
| Warning | `#d4a56a` | Gentle warnings, attention needed |
| Warning Background | `#faf3e8` | Warning message backgrounds |
| Error | `#c97070` | Errors, required fields |
| Error Background | `#faf0f0` | Error message backgrounds |
| Info | `#8aacc8` | Informational, help text |
| Info Background | `#f0f5fa` | Info message backgrounds |

## Shadows

| Role | Value | Usage |
|------|-------|-------|
| Soft | `0 2px 12px rgba(61, 53, 48, 0.06)` | Cards, slight lift |
| Medium | `0 4px 24px rgba(61, 53, 48, 0.08)` | Hover cards, dropdowns |
| Warm Glow | `0 0 20px rgba(212, 165, 165, 0.15)` | Primary element emphasis |

## CSS Variables

```css
:root {
  /* Primary */
  --color-primary: #d4a5a5;
  --color-primary-hover: #c79393;
  --color-primary-light: #e8cece;
  --color-primary-muted: #f5ebe7;

  /* Accent */
  --color-accent: #9caf88;
  --color-accent-hover: #8a9d76;
  --color-accent-light: #c5d4b8;
  --color-tertiary: #c8a87e;

  /* Text */
  --color-text-primary: #3d3530;
  --color-text-secondary: #7a6e65;
  --color-text-tertiary: #b0a59c;
  --color-text-inverse: #fdf6ee;
  --color-text-link: #b07878;

  /* Surface */
  --color-bg: #fdf6ee;
  --color-surface-1: #ffffff;
  --color-surface-2: #f8f0e5;
  --color-surface-3: #f0e6d8;
  --color-border: #e8ddd0;
  --color-border-subtle: #f0e6d8;
  --color-border-focus: #d4a5a5;

  /* Semantic */
  --color-success: #9caf88;
  --color-success-bg: #f0f5ec;
  --color-warning: #d4a56a;
  --color-warning-bg: #faf3e8;
  --color-error: #c97070;
  --color-error-bg: #faf0f0;
  --color-info: #8aacc8;
  --color-info-bg: #f0f5fa;

  /* Shadows */
  --shadow-soft: 0 2px 12px rgba(61, 53, 48, 0.06);
  --shadow-medium: 0 4px 24px rgba(61, 53, 48, 0.08);
  --shadow-warm-glow: 0 0 20px rgba(212, 165, 165, 0.15);
}
```
