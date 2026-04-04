# Design System: Raycast — Component Stylings

## Buttons

- **Primary Pill**: Transparent background, white text, pill shape (86px radius), multi-layer inset shadow (`rgba(255, 255, 255, 0.1) 0px 1px 0px 0px inset`). Hover: opacity 0.6
- **Secondary Button**: Transparent background, white text, 6px radius, `1px solid rgba(255, 255, 255, 0.1)` border, subtle drop shadow (`rgba(0, 0, 0, 0.03) 0px 7px 3px`). Hover: opacity 0.6
- **Ghost Button**: No background or border, gray text (`#6a6b6c`), 86px radius, same inset shadow. Hover: opacity 0.6, text brightens to white
- **CTA (Download)**: Semi-transparent white background (`hsla(0, 0%, 100%, 0.815)`), dark text (`#18191a`), pill shape. Hover: full white background (`hsl(0, 0%, 100%)`)
- **Transition**: All buttons use opacity transition for hover rather than background-color change — a signature Raycast interaction pattern

## Cards & Containers

- **Standard Card**: `#101111` surface, `1px solid rgba(255, 255, 255, 0.06)` border, 12px–16px border-radius
- **Elevated Card**: Ring shadow `rgb(27, 28, 30) 0px 0px 0px 1px` outer + `rgb(7, 8, 10) 0px 0px 0px 1px inset` inner — creates a double-ring containment
- **Feature Card**: 16px–20px border-radius, subtle warm glow (`rgba(215, 201, 175, 0.05) 0px 0px 20px 5px`) behind hero elements
- **Hover**: Cards brighten slightly via border opacity increase or subtle shadow enhancement

## Inputs & Forms

- Dark input fields with `#07080a` background, `1px solid rgba(255, 255, 255, 0.08)` border, 8px border-radius
- Focus state: Border brightens, blue glow (`hsla(202, 100%, 67%, 0.15)`) ring appears
- Text: `#f9f9f9` input color, `#6a6b6c` placeholder
- Labels: `#9c9c9d` at 14px weight 500

## Navigation

- **Top nav**: Dark background blending with page, white text links at 16px weight 500
- **Nav links**: Gray text (`#9c9c9d`) → white on hover, underline decoration on hover
- **CTA button**: Semi-transparent white pill at nav end
- **Mobile**: Collapses to hamburger, maintains dark theme
- **Sticky**: Nav fixed at top with subtle border separator

## Image Treatment

- **Product screenshots**: macOS window chrome style — rounded corners (12px), deep shadows simulating floating windows
- **Full-bleed sections**: Dark screenshots blend seamlessly into the dark background
- **Hero illustration**: Diagonal stripe pattern in Raycast Red — abstract, geometric, brand-defining
- **App UI embeds**: Showing actual Raycast command palette and extensions — product as content

## Keyboard Shortcut Keys

- **Key cap styling**: Gradient background (`#121212` → `#0d0d0d`), heavy multi-layer shadow (`rgba(0, 0, 0, 0.4) 0px 1.5px 0.5px 2.5px` + inset shadows), creating realistic physical key appearance
- Border-radius: 4px–6px for individual keys

## Badges & Tags

- **Neutral badge**: `#1b1c1e` background, white text, 6px radius, 14px font at weight 500, `0px 6px` padding
- Compact, pill-like treatment for categorization
