<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: ElevenLabs — Component Stylings

## Buttons

**Primary Black Pill** — bg `#000000`, text `#ffffff`, padding `0px 14px`, radius `9999px`. Use: Primary CTA.

**White Pill (Shadow-bordered)** — bg `#ffffff`, text `#000000`, radius `9999px`, shadow `rgba(0,0,0,0.4) 0px 0px 1px, rgba(0,0,0,0.04) 0px 4px 4px`. Use: Secondary CTA on white.

**Warm Stone Pill** — bg `rgba(245,242,239,0.8)`, text `#000000`, padding `12px 20px 12px 14px` (asymmetric), radius `30px`, shadow `rgba(78,50,23,0.04) 0px 6px 16px`. Use: Featured CTA, hero action — the signature warm button.

**Uppercase Waldenburg Button** — font WaldenburgFH 14px weight 700, text-transform uppercase, letter-spacing 0.7px. Use: Specific bold CTA labels.

> **Button pattern:** Pill shapes dominate (radius 9999px or 30px). Warm Stone variant creates a physical, tactile quality unique to ElevenLabs via asymmetric padding and warm-tinted shadow.

## Cards & Containers

- bg `#ffffff`; border `1px solid #e5e5e5` or shadow-as-border; radius 16px–24px
- Shadow: multi-layer stack (inset + outline + elevation)
- Content: product screenshots, code examples, audio waveform previews

## Inputs & Forms

- Textarea: padding `12px 20px`, transparent text at default; Select: white bg, standard styling
- Radio: standard with tw-ring focus; Focus: `var(--tw-ring-offset-shadow)` ring system

## Navigation

- Sticky white header; Inter 15px weight 500 for nav links; pill CTAs right-aligned (black primary, white secondary)
- Mobile: hamburger collapse at 1024px

## Images

- Product screenshots and audio waveform visualizations; warm gradient backgrounds in feature sections
- 20px–24px radius on image containers; full-width sections alternating white and light gray

## Distinctive Components

**Audio Waveform Sections** — colorful gradient backgrounds (warm amber, blue, green) behind voice AI product demos.

**Warm Stone CTA Block** — `rgba(245,242,239,0.8)` bg, warm shadow, asymmetric padding (more right). Creates physical, tactile quality unique to ElevenLabs.
