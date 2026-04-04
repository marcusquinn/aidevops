<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Clay Design System: Component Stylings

## Buttons

**Primary (Transparent)**

- Background: transparent (`rgba(239, 241, 243, 0)`); Text: `#000000`; Padding: 6.4px 12.8px
- Border: none (or `1px solid #717989` for outlined variant)
- Hover: background → swatch color (e.g., `#434346`), text → white, `rotateZ(-8deg)`, `translateY(-80%)`, hard shadow `rgb(0,0,0) -7px 7px`
- Focus: `rgb(20, 110, 245) solid 2px` outline

**White Solid** — Primary CTA on colored sections

- Background: `#ffffff`; Text: `#000000`; Padding: 6.4px
- Hover: oat-200 swatch, animated rotation + shadow

**Ghost Outlined**

- Background: transparent; Text: `#000000`; Padding: 8px; Border: `1px solid #717989`; Radius: 4px
- Hover: dragonfruit swatch, white text, animated rotation

## Cards & Containers

- Background: `#ffffff` on cream canvas
- Border: `1px solid #dad4c8` (warm oat) or `1px dashed #dad4c8` (secondary/decorative — adds hand-drawn quality)
- Radius: 12px (standard), 24px (feature cards/images), 40px (section containers/footer)
- Shadow: `rgba(0,0,0,0.1) 0px 1px 1px, rgba(0,0,0,0.04) 0px -1px 1px inset, rgba(0,0,0,0.05) 0px -0.5px 1px`
- Swatch color sections: full-width backgrounds (matcha green, slushie cyan, ube purple, lemon gold); white text on dark swatches, black on light

## Inputs & Forms

- Text: `#000000`; Border: `1px solid #717989`; Radius: 4px
- Focus: `rgb(20, 110, 245) solid 2px` outline

## Navigation

- Sticky top nav on cream background; border-bottom: `1px solid #dad4c8`
- Roobert 15px weight 500 for nav links; Clay logo left, CTA buttons right (pill radius)
- Mobile: hamburger collapse at 767px

## Images

- Product screenshots in white cards with oat borders; 8px–24px radius
- Colorful illustrated sections with swatch background colors; full-width section backgrounds
