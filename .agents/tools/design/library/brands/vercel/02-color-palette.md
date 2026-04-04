<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Vercel — Color Palette & Roles

## Primary

- **Vercel Black** (`#171717`): Primary text, headings, dark surface backgrounds. Not pure black — the slight warmth prevents harshness.
- **Pure White** (`#ffffff`): Page background, card surfaces, button text on dark.
- **True Black** (`#000000`): Secondary use, `--geist-console-text-color-default`, used in specific console/code contexts.

## Workflow Accent Colors

- **Ship Red** (`#ff5b4f`): `--ship-text`, the "ship to production" workflow step — warm, urgent coral-red.
- **Preview Pink** (`#de1d8d`): `--preview-text`, the preview deployment workflow — vivid magenta-pink.
- **Develop Blue** (`#0a72ef`): `--develop-text`, the development workflow — bright, focused blue.

## Console / Code Colors

- **Console Blue** (`#0070f3`): `--geist-console-text-color-blue`, syntax highlighting blue.
- **Console Purple** (`#7928ca`): `--geist-console-text-color-purple`, syntax highlighting purple.
- **Console Pink** (`#eb367f`): `--geist-console-text-color-pink`, syntax highlighting pink.

## Interactive

- **Link Blue** (`#0072f5`): Primary link color with underline decoration.
- **Focus Blue** (`hsla(212, 100%, 48%, 1)`): `--ds-focus-color`, focus ring on interactive elements.
- **Ring Blue** (`rgba(147, 197, 253, 0.5)`): `--tw-ring-color`, Tailwind ring utility.

## Neutral Scale

- **Gray 900** (`#171717`): Primary text, headings, nav text.
- **Gray 600** (`#4d4d4d`): Secondary text, description copy.
- **Gray 500** (`#666666`): Tertiary text, muted links.
- **Gray 400** (`#808080`): Placeholder text, disabled states.
- **Gray 100** (`#ebebeb`): Borders, card outlines, dividers.
- **Gray 50** (`#fafafa`): Subtle surface tint, inner shadow highlight.

## Surface & Overlay

- **Overlay Backdrop** (`hsla(0, 0%, 98%, 1)`): `--ds-overlay-backdrop-color`, modal/dialog backdrop.
- **Selection Text** (`hsla(0, 0%, 95%, 1)`): `--geist-selection-text-color`, text selection highlight.
- **Badge Blue Bg** (`#ebf5ff`): Pill badge background, tinted blue surface.
- **Badge Blue Text** (`#0068d6`): Pill badge text, darker blue for readability.

## Shadows & Depth

- **Border Shadow** (`rgba(0, 0, 0, 0.08) 0px 0px 0px 1px`): The signature — replaces traditional borders.
- **Subtle Elevation** (`rgba(0, 0, 0, 0.04) 0px 2px 2px`): Minimal lift for cards.
- **Card Stack** (`rgba(0,0,0,0.08) 0px 0px 0px 1px, rgba(0,0,0,0.04) 0px 2px 2px, rgba(0,0,0,0.04) 0px 8px 8px -8px, #fafafa 0px 0px 0px 1px`): Full multi-layer card shadow.
- **Ring Border** (`rgb(235, 235, 235) 0px 0px 0px 1px`): Light gray ring-border for tabs and images.
