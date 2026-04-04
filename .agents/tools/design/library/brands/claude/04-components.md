<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Claude — Component Stylings

## Buttons

| Variant | Background | Text | Padding | Radius | Notes |
|---------|-----------|------|---------|--------|-------|
| Warm Sand (Secondary) | `#e8e6dc` | `#4d4c48` | `0px 12px 0px 8px` | `8px` | Asymmetric — icon-first; shadow: `#e8e6dc 0px 0px 0px 0px, #d1cfc5 0px 0px 0px 1px` |
| White Surface | `#ffffff` | `#141413` | `8px 16px 8px 12px` | `12px` | Hover: shifts to secondary bg |
| Dark Charcoal | `#30302e` | `#faf9f5` | `0px 12px 0px 8px` | `8px` | Shadow: `#30302e 0px 0px 0px 0px, ring 0px 0px 0px 1px` |
| Brand Terracotta | `#c96442` | `#faf9f5` | `0px 12px 0px 8px` | `8–12px` | Primary CTA; only chromatic button; shadow: `#c96442 0px 0px 0px 0px, #c96442 0px 0px 0px 1px` |
| Dark Primary | `#141413` | `#b0aea5` | `9.6px 16.8px` | `12px` | Border: `1px solid #30302e` (dark theme surfaces) |

## Cards & Containers

- Background: `#faf9f5` / `#ffffff` (light) · `#30302e` (dark)
- Border: `1px solid #f0eee6` (light) · `1px solid #30302e` (dark)
- Radius: 8px standard · 16px featured · 32px hero/embedded media
- Shadow: `rgba(0,0,0,0.05) 0px 4px 24px` (elevated) · `0px 0px 0px 1px` ring (interactive states)
- Section borders: `1px 0px 0px` top-only for list item separators

## Inputs & Forms

- Text: `#141413` · Padding: `1.6px 12px` · Radius: `12px`
- Focus: `#3898ec` border-color — only cool color in system

## Navigation

- Sticky top nav, warm background; Claude wordmark in `#141413`
- Links: `#141413` / `#5e5d59` / `#3d3d3a`; nav border: `1px solid #30302e` (dark) · `1px solid #f0eee6` (light)
- CTA: Terracotta Brand or White Surface button; hover: text → foreground-primary, no decoration

## Image Treatment

- Product screenshots: generous border-radius (16–32px); dark UI on warm light canvas
- Embedded video players with rounded corners
- Organic, hand-drawn illustrations for conceptual sections

## Distinctive Components

**Model Comparison Cards** — Opus 4.5 / Sonnet 4.5 / Haiku 4.5 in bordered card grid; name, description, capability badges; `#e8e6dc` border separation.

**Organic Illustrations** — Hand-drawn-feeling vectors in terracotta, black, muted green; abstract/conceptual (not literal product diagrams).

**Dark/Light Section Alternation** — Page alternates Parchment light and Near Black dark sections; each is a distinct visual environment.
