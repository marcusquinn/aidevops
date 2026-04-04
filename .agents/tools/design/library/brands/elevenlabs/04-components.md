<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: ElevenLabs — Component Stylings

## Buttons

**Primary Black Pill**
- Background: `#000000`
- Text: `#ffffff`
- Padding: 0px 14px
- Radius: 9999px (full pill)
- Use: Primary CTA

**White Pill (Shadow-bordered)**
- Background: `#ffffff`
- Text: `#000000`
- Radius: 9999px
- Shadow: `rgba(0,0,0,0.4) 0px 0px 1px, rgba(0,0,0,0.04) 0px 4px 4px`
- Use: Secondary CTA on white

**Warm Stone Pill**
- Background: `rgba(245, 242, 239, 0.8)` (warm translucent)
- Text: `#000000`
- Padding: 12px 20px 12px 14px (asymmetric)
- Radius: 30px
- Shadow: `rgba(78, 50, 23, 0.04) 0px 6px 16px` (warm-tinted)
- Use: Featured CTA, hero action — the signature warm button

**Uppercase Waldenburg Button**
- Font: WaldenburgFH 14px weight 700
- Text-transform: uppercase
- Letter-spacing: 0.7px
- Use: Specific bold CTA labels

## Cards & Containers

- Background: `#ffffff`
- Border: `1px solid #e5e5e5` or shadow-as-border
- Radius: 16px–24px
- Shadow: multi-layer stack (inset + outline + elevation)
- Content: product screenshots, code examples, audio waveform previews

## Inputs & Forms

- Textarea: padding 12px 20px, transparent text at default
- Select: white background, standard styling
- Radio: standard with tw-ring focus
- Focus: `var(--tw-ring-offset-shadow)` ring system

## Navigation

- Clean white sticky header
- Inter 15px weight 500 for nav links
- Pill CTAs right-aligned (black primary, white secondary)
- Mobile: hamburger collapse at 1024px

## Image Treatment

- Product screenshots and audio waveform visualizations
- Warm gradient backgrounds in feature sections
- 20px–24px radius on image containers
- Full-width sections alternating white and light gray

## Distinctive Components

**Audio Waveform Sections**
- Colorful gradient backgrounds showcasing voice AI capabilities
- Warm amber, blue, and green gradients behind product demos
- Screenshots of the ElevenLabs product interface

**Warm Stone CTA Block**
- `rgba(245,242,239,0.8)` background with warm shadow
- Asymmetric padding (more right padding)
- Creates a physical, tactile quality unique to ElevenLabs
