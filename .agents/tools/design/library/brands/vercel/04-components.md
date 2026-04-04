<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Vercel — Component Stylings

## Buttons

| Variant | Background | Text | Padding | Radius | Use |
|---------|-----------|------|---------|--------|-----|
| White (shadow-bordered) | `#ffffff` | `#171717` | `0px 6px` | `6px` | Secondary |
| Dark (Geist) | `#171717` | `#ffffff` | `8px 16px` | `6px` | Primary CTA |
| Pill / Badge | `#ebf5ff` | `#0068d6` | `0px 10px` | `9999px` | Status badges, tags |
| Large Pill (nav) | transparent / `#171717` | — | — | `64px–100px` | Tab nav, section selectors |

White button states: hover → `var(--ds-gray-1000)` bg; focus → `2px solid var(--ds-focus-color)` + `var(--ds-focus-ring)` shadow. Pill font: 12px weight 500.

## Cards & Containers

- Background: `#ffffff` / Radius: 8px (standard), 12px (featured/image)
- Border: shadow — `rgba(0,0,0,0.08) 0px 0px 0px 1px`
- Shadow stack: `rgba(0,0,0,0.08) 0px 0px 0px 1px, rgba(0,0,0,0.04) 0px 2px 2px, #fafafa 0px 0px 0px 1px`
- Image cards: `1px solid #ebebeb` / top radius 12px / hover: subtle shadow intensification

## Inputs & Forms

- Border: shadow technique (not traditional border)
- Focus outline: `2px solid var(--ds-focus-color)` (blue ring)
- Focus shadow: `1px 0 0 0 var(--ds-gray-alpha-600)`
- Radio focus background: `var(--ds-gray-200)`

## Navigation

- Horizontal, white, sticky / Vercel logotype left-aligned 262×52px
- Links: Geist 14px weight 500, `#171717`; active: weight 600 or underline
- CTA: dark pill buttons ("Start Deploying", "Contact Sales")
- Mobile: hamburger collapse / product dropdowns with multi-level menus

## Image Treatment

- Product screenshots: `1px solid #ebebeb` border / top-rounded: `12px 12px 0px 0px`
- Dashboard/code preview screenshots dominate feature sections
- Soft pastel gradient backgrounds behind hero images

## Distinctive Components

**Workflow Pipeline** — Three-step horizontal: Develop → Preview → Ship. Accent colors: Blue → Pink → Red; connected with lines/arrows. Visual metaphor for Vercel's core value proposition.

**Trust Bar / Logo Grid** — Company logos (Perplexity, ChatGPT, Cursor, etc.) in grayscale; horizontal scroll or grid with `#ebebeb` border separation.

**Metric Cards** — Large number display (e.g., "10x faster") in Geist 48px weight 600; gray body text below; shadow-bordered card container.
