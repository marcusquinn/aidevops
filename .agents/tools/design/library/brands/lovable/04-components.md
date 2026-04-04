<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Lovable — Component Stylings

## Buttons

Shared across all button variants: Padding 8px 16px · Radius 6px · Active opacity 0.8 · Focus `rgba(0,0,0,0.1) 0px 4px 12px` shadow

**Primary Dark (Inset Shadow)**
- Background: `#1c1c1c` · Text: `#fcfbf8`
- Shadow: `rgba(0,0,0,0) 0px 0px 0px 0px, rgba(0,0,0,0) 0px 0px 0px 0px, rgba(255,255,255,0.2) 0px 0.5px 0px 0px inset, rgba(0,0,0,0.2) 0px 0px 0px 0.5px inset, rgba(0,0,0,0.05) 0px 1px 2px 0px`
- Use: Primary CTA ("Start Building", "Get Started")

**Ghost / Outline**
- Background: transparent · Text: `#1c1c1c`
- Border: `1px solid rgba(28,28,28,0.4)`
- Use: Secondary actions ("Log In", "Documentation")

**Cream Surface**
- Background: `#f7f4ed` · Text: `#1c1c1c` · No border
- Use: Tertiary actions, toolbar buttons

**Pill / Icon Button**
- Background: `#f7f4ed` · Text: `#1c1c1c` · Radius: 9999px (full pill)
- Shadow: same inset pattern as Primary Dark
- Opacity: 0.5 (default), 0.8 (active)
- Use: Additional actions, plan mode toggle, voice recording

## Cards & Containers

- Background: `#f7f4ed` · Border: `1px solid #eceae4`
- Radius: 12px (standard), 16px (featured), 8px (compact)
- No box-shadow by default — borders define boundaries

## Inputs & Forms

- Background: `#f7f4ed` · Text: `#1c1c1c` · Border: `1px solid #eceae4` · Radius: 6px
- Focus: ring blue (`rgba(59,130,246,0.5)`) outline · Placeholder: `#5f5f5d`

## Navigation

- Clean horizontal nav on cream background, fixed
- Logo/wordmark left-aligned (128.75 x 22px)
- Links: Camera Plain 14–16px weight 400, `#1c1c1c` text
- CTA: dark button with inset shadow, 6px radius
- Mobile: hamburger menu with 6px radius button
- Subtle border or no border on scroll

## Links

- Color: `#1c1c1c` · Decoration: underline (default)
- Hover: primary accent (via CSS variable `hsl(var(--primary))`)
- No color change on hover — decoration carries the interactive signal

## Image Treatment

- Showcase/portfolio images: `1px solid #eceae4` border, 12px radius on all containers
- Soft gradient backgrounds behind hero content (warm multi-color wash)
- Gallery-style presentation for template/project showcases

## Distinctive Components

**AI Chat Input**
- Large prompt input area with soft borders
- Suggestion pills with `#eceae4` borders
- Voice recording / plan mode toggle as pill shapes (9999px)
- Warm, inviting input area — not clinical

**Template Gallery**
- Card grid: image + title, `1px solid #eceae4` border, 12px radius
- Hover: subtle shadow or border darkening · Category labels as text links

**Stats Bar**
- Large metrics: "0M+" pattern in 48px+ weight 600
- Descriptive text below in muted gray · Horizontal layout with generous spacing
