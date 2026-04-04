<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoltAgent Design System: Color Palette & Roles

## Primary

- **Emerald Signal Green** (`#00d992`): The core brand energy — used for accent borders, glow effects, and the highest-signal interactive moments. This is the "power-on" indicator of the entire interface.
- **VoltAgent Mint** (`#2fd6a1`): The button-text variant of the brand green — slightly warmer and more readable than pure Signal Green, used specifically for CTA text on dark surfaces.
- **Tailwind Emerald** (`#10b981`): The ecosystem-standard green used at low opacity (30%) for subtle background tints and link defaults. Bridges VoltAgent's custom palette with Tailwind's utility classes.

## Secondary & Accent

- **Soft Purple** (`#818cf8`): A cool indigo-violet used sparingly for secondary categorization, code syntax highlights, and visual variety without competing with green.
- **Cobalt Primary** (`#306cce`): Docusaurus primary dark — used in documentation contexts for links and interactive focus states.
- **Deep Cobalt** (`#2554a0`): The darkest primary shade, reserved for pressed/active states in documentation UI.
- **Ring Blue** (`#3b82f6`): Tailwind's ring color at 50% opacity — visible only during keyboard focus for accessibility compliance.

## Surface & Background

- **Abyss Black** (`#050507`): The landing page canvas — a near-pure black with the faintest warm undertone, darker than most "dark themes" for maximum contrast with green accents.
- **Carbon Surface** (`#101010`): The primary card and button background — one shade lighter than Abyss, creating a barely perceptible elevation layer. Used across all contained surfaces.
- **Warm Charcoal Border** (`#3d3a39`): The signature containment color — not a cold gray but a warm, almost brownish dark tone that prevents borders from feeling harsh against the black canvas.

## Neutrals & Text

- **Snow White** (`#f2f2f2`): The primary text color on dark surfaces — not pure white (`#ffffff`) but a softened, eye-friendly off-white. The most-used color on the site (1008 instances).
- **Pure White** (`#ffffff`): Reserved for the highest-emphasis moments — ghost button text and maximum-contrast headings. Used at low opacity (5%) for subtle overlay effects.
- **Warm Parchment** (`#b8b3b0`): Secondary body text — a warm light gray with a slight pinkish undertone that reads as "paper" against the dark canvas.
- **Steel Slate** (`#8b949e`): Tertiary text, metadata, timestamps, and de-emphasized content. A cool blue-gray that provides clear hierarchy below Warm Parchment.
- **Fog Gray** (`#bdbdbd`): Footer links and supporting navigation text — brightens on hover to Pure White.
- **Mist Gray** (`#dcdcdc`): Slightly brighter than Fog, used for secondary link text that transitions to bright green on hover.
- **Near White** (`#eeeeee`): Highest-contrast secondary text, one step below Snow White.

## Semantic & Accent

- **Success Emerald** (`#008b00`): Deep green for success states and positive confirmations in documentation contexts.
- **Success Light** (`#80d280`): Soft pastel green for success backgrounds and subtle positive indicators.
- **Warning Amber** (`#ffba00`): Bright amber for warning alerts and caution states.
- **Warning Pale** (`#ffdd80`): Softened amber for warning background fills.
- **Danger Coral** (`#fb565b`): Vivid red for error states and destructive action warnings.
- **Danger Rose** (`#fd9c9f`): Softened coral-pink for error backgrounds.
- **Info Teal** (`#4cb3d4`): Cool teal-blue for informational callouts and tip admonitions.
- **Dashed Border Slate** (`#4f5d75` at 40%): A muted blue-gray used exclusively for decorative dashed borders in workflow diagrams.

## Gradient System

- **Green Signal Glow**: `drop-shadow(0 0 2px #00d992)` animating to `drop-shadow(0 0 8px #00d992)` — creates a pulsing "electric charge" effect on the VoltAgent bolt logo and interactive elements. The glow expands and contracts like a heartbeat.
- **Warm Ambient Haze**: `rgba(92, 88, 85, 0.2) 0px 0px 15px` — a warm-toned diffused shadow that creates a soft atmospheric glow around elevated cards, visible at the edges without sharp boundaries.
- **Deep Dramatic Elevation**: `rgba(0, 0, 0, 0.7) 0px 20px 60px` with `rgba(148, 163, 184, 0.1) 0px 0px 0px 1px inset` — a heavy, dramatic downward shadow paired with a faint inset slate ring for the most prominent floating elements.
