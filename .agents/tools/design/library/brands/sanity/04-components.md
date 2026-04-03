# Design System: Sanity — Component Stylings

## Buttons

**Primary CTA (Pill)**
- Background: Sanity Red (`#f36458`)
- Text: White (`#ffffff`)
- Padding: 8px 16px
- Border Radius: 99999px (full pill)
- Border: none
- Hover: Electric Blue (`#0052ef`) background, white text
- Font: 16px waldenburgNormal, weight 400

**Secondary (Dark Pill)**
- Background: Near Black (`#0b0b0b`)
- Text: Silver (`#b9b9b9`)
- Padding: 8px 12px
- Border Radius: 99999px (full pill)
- Border: none
- Hover: Electric Blue (`#0052ef`) background, white text

**Outlined (Light Pill)**
- Background: White (`#ffffff`)
- Text: Near Black (`#0b0b0b`)
- Padding: 8px
- Border Radius: 99999px (full pill)
- Border: 1px solid `#0b0b0b`
- Hover: Electric Blue (`#0052ef`) background, white text

**Ghost / Subtle**
- Background: Dark Gray (`#212121`)
- Text: Silver (`#b9b9b9`)
- Padding: 0px 12px
- Border Radius: 5px
- Border: 1px solid `#212121`
- Hover: Electric Blue (`#0052ef`) background, white text

**Uppercase Label Button**
- Font: 11px waldenburgNormal, weight 600, uppercase
- Background: transparent or `#212121`
- Text: Silver (`#b9b9b9`)
- Letter-spacing: normal
- Used for tab-like navigation and filter controls

## Cards

**Dark Content Card**
- Background: `#212121`
- Border: 1px solid `#353535` or `#212121`
- Border Radius: 6px
- Padding: 24px
- Text: White (`#ffffff`) for titles, Silver (`#b9b9b9`) for body
- Hover: subtle border color shift or elevation change

**Feature Card (Full-bleed)**
- Background: `#0b0b0b` or full-bleed image/gradient
- Border: none or 1px solid `#212121`
- Border Radius: 12px
- Padding: 32-48px
- Contains large imagery with overlaid text

## Inputs

**Text Input / Textarea**
- Background: Near Black (`#0b0b0b`)
- Text: Silver (`#b9b9b9`)
- Border: 1px solid `#212121`
- Padding: 8px 12px
- Border Radius: 3px
- Focus: outline with `var(--focus-ring-color)` (blue), 2px solid
- Focus background: shifts to deep cyan (`#072227`)

**Search Input**
- Background: `#0b0b0b`
- Text: Silver (`#b9b9b9`)
- Padding: 0px 12px
- Border Radius: 3px
- Placeholder: Medium Gray (`#797979`)

## Navigation

**Top Navigation**
- Background: Near Black (`#0b0b0b`) with backdrop blur
- Height: auto, compact padding
- Logo: left-aligned, Sanity wordmark
- Links: waldenburgNormal 16px, Silver (`#b9b9b9`)
- Link Hover: Electric Blue via `--color-fg-accent-blue`
- CTA Button: Sanity Red pill button right-aligned
- Separator: 1px border-bottom `#212121`

**Footer**
- Background: Near Black (`#0b0b0b`)
- Multi-column link layout
- Links: Silver (`#b9b9b9`), hover to blue
- Section headers: White (`#ffffff`), 13px uppercase IBM Plex Mono

## Badges / Pills

**Neutral Subtle**
- Background: White (`#ffffff`)
- Text: Near Black (`#0b0b0b`)
- Padding: 8px
- Font: 13px
- Border Radius: 99999px

**Neutral Filled**
- Background: Near Black (`#0b0b0b`)
- Text: White (`#ffffff`)
- Padding: 8px
- Font: 13px
- Border Radius: 99999px
