<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Mintlify: Component Stylings

## Buttons

**Primary Brand (Full-round)**
- Background: `#0d0d0d`
- Text: `#ffffff`
- Padding: 8px 24px
- Radius: 9999px
- Font: Inter 15px weight 500
- Shadow: `rgba(0,0,0,0.06) 0px 1px 2px`
- Hover: opacity 0.9
- Use: Primary CTA ("Get Started", "Start Building")

**Secondary / Ghost (Full-round)**
- Background: `#ffffff`
- Text: `#0d0d0d`
- Padding: 4.5px 12px
- Radius: 9999px
- Border: `1px solid rgba(0,0,0,0.08)`
- Font: Inter 15px weight 500
- Hover: opacity 0.9
- Use: Secondary actions ("Request Demo", "View Docs")

**Transparent / Nav Button**
- Background: transparent
- Text: `#0d0d0d`
- Padding: 5px 6px
- Radius: 8px
- Border: none or `1px solid rgba(0,0,0,0.05)`
- Use: Navigation items, icon buttons

**Brand Accent Button**
- Background: `#18E299`
- Text: `#0d0d0d`
- Padding: 8px 24px
- Radius: 9999px
- Use: Special promotional CTAs

## Cards & Containers

**Standard Card**
- Background: `#ffffff`
- Border: `1px solid rgba(0,0,0,0.05)`
- Radius: 16px
- Padding: 24px
- Shadow: `rgba(0,0,0,0.03) 0px 2px 4px`
- Hover: border darkens to `rgba(0,0,0,0.08)`

**Featured Card**
- Background: `#ffffff`
- Border: `1px solid rgba(0,0,0,0.05)`
- Radius: 24px
- Padding: 32px
- Inner content areas: 16px radius

**Logo/Trust Card**
- Background: `#fafafa` or `#ffffff`
- Border: `1px solid rgba(0,0,0,0.05)`
- Radius: 16px
- Centered logo/icon with consistent sizing

## Inputs & Forms

**Email Input**
- Background: transparent or `#ffffff`
- Text: `#0d0d0d`
- Padding: 0px 12px
- Border: `1px solid rgba(0,0,0,0.08)`
- Radius: 9999px
- Focus: `1px solid var(--color-brand)` + `outline: 1px solid var(--color-brand)`
- Placeholder: `#888888`

## Navigation

- Horizontal nav on white, sticky with backdrop blur
- Brand logotype left-aligned
- Links: Inter 14–15px weight 500, `#0d0d0d`
- Hover: shifts to `var(--color-brand)`
- CTA: dark pill button right-aligned ("Get Started")
- Mobile: hamburger collapse at 768px

## Image Treatment

- Product screenshots with subtle 1px borders
- Rounded containers: 16px–24px radius
- Atmospheric gradient backgrounds behind hero images
- Cloud/sky imagery with soft green tinting

## Distinctive Components

**Atmospheric Hero**
- Full-width gradient wash: soft green-to-white cloud-like gradient
- Centered headline with tight tracking
- Subtitle in muted gray
- Dual CTA buttons (dark primary + ghost secondary)

**Trust Bar / Logo Grid**
- "Loved by your favorite companies" section
- Company logos in muted grayscale
- Grid or horizontal layout with consistent sizing
- Subtle border separation between logos

**Feature Cards with Icons**
- Icon or illustration at top
- Title: 20px weight 600
- Description: 14–16px in gray
- Consistent padding and border treatment
- Grid: 2–3 columns on desktop

**CTA Footer Section**
- Dark or gradient background
- Large headline: "Make documentation your winning advantage"
- Email input with pill styling
- Brand green accent on CTAs
