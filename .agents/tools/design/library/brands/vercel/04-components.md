<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Vercel — Component Stylings

## Buttons

**Primary White (Shadow-bordered)**
- Background: `#ffffff` / Text: `#171717`
- Padding: 0px 6px (content-driven width) / Radius: 6px
- Shadow: `rgb(235, 235, 235) 0px 0px 0px 1px`
- Hover: background → `var(--ds-gray-1000)` (dark)
- Focus: `2px solid var(--ds-focus-color)` + `var(--ds-focus-ring)` shadow
- Use: Standard secondary button

**Primary Dark (Geist system)**
- Background: `#171717` / Text: `#ffffff`
- Padding: 8px 16px / Radius: 6px
- Use: Primary CTA ("Start Deploying", "Get Started")

**Pill Button / Badge**
- Background: `#ebf5ff` / Text: `#0068d6`
- Padding: 0px 10px / Radius: 9999px / Font: 12px weight 500
- Use: Status badges, tags, feature labels

**Large Pill (Navigation)**
- Background: transparent or `#171717` / Radius: 64px–100px
- Use: Tab navigation, section selectors

## Cards & Containers

- Background: `#ffffff`
- Border: shadow — `rgba(0, 0, 0, 0.08) 0px 0px 0px 1px`
- Radius: 8px (standard), 12px (featured/image cards)
- Shadow stack: `rgba(0,0,0,0.08) 0px 0px 0px 1px, rgba(0,0,0,0.04) 0px 2px 2px, #fafafa 0px 0px 0px 1px`
- Image cards: `1px solid #ebebeb` / top radius 12px
- Hover: subtle shadow intensification

## Inputs & Forms

- Radio: focus background `var(--ds-gray-200)`
- Focus shadow: `1px 0 0 0 var(--ds-gray-alpha-600)`
- Focus outline: `2px solid var(--ds-focus-color)` (blue focus ring)
- Border: shadow technique, not traditional border

## Navigation

- Horizontal nav, white, sticky
- Vercel logotype left-aligned, 262x52px
- Links: Geist 14px weight 500, `#171717`; active: weight 600 or underline
- CTA: dark pill buttons ("Start Deploying", "Contact Sales")
- Mobile: hamburger collapse / product dropdowns with multi-level menus

## Image Treatment

- Product screenshots: `1px solid #ebebeb` border
- Top-rounded images: `12px 12px 0px 0px` radius
- Dashboard/code preview screenshots dominate feature sections
- Soft gradient backgrounds behind hero images (pastel multi-color)

## Distinctive Components

**Workflow Pipeline**
- Three-step horizontal: Develop → Preview → Ship
- Accent colors: Blue → Pink → Red; connected with lines/arrows
- Visual metaphor for Vercel's core value proposition

**Trust Bar / Logo Grid**
- Company logos (Perplexity, ChatGPT, Cursor, etc.) in grayscale
- Horizontal scroll or grid / `#ebebeb` border separation

**Metric Cards**
- Large number display (e.g., "10x faster") — Geist 48px weight 600
- Description below in gray body text / shadow-bordered card container
