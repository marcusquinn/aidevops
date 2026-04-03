# Design System: Sanity — Color Palette & Roles

## Primary Brand

- **Sanity Black** (`#0b0b0b`): The primary canvas and dominant surface color. Not pure black but close enough to feel absolute. The foundation of the entire visual identity.
- **Pure Black** (`#000000`): Used for maximum-contrast moments, deep overlays, and certain border accents.
- **Sanity Red** (`#f36458`): The primary CTA and brand accent -- a warm coral-red that serves as the main call-to-action color. Used for "Get Started" buttons and primary conversion points.

## Accent & Interactive

- **Electric Blue** (`#0052ef`): The universal hover/active state color across the entire system. Buttons, links, and interactive elements all shift to this blue on hover. Also used as `--color-blue-700` for focus rings and active states.
- **Light Blue** (`#55beff` / `#afe3ff`): Secondary blue variants used for accent backgrounds, badges, and dimmed blue surfaces.
- **Neon Green** (`color(display-p3 .270588 1 0)`): A vivid, wide-gamut green used as `--color-fg-accent-green` for success states and premium feature highlights. Falls back to `#19d600` in sRGB.
- **Accent Magenta** (`color(display-p3 .960784 0 1)`): A vivid wide-gamut magenta for specialized accent moments.

## Surface & Background

- **Near Black** (`#0b0b0b`): Default page background and primary surface.
- **Dark Gray** (`#212121`): Elevated surface color for cards, secondary containers, input backgrounds, and subtle layering above the base canvas.
- **Medium Dark** (`#353535`): Tertiary surface and border color for creating depth between dark layers.
- **Pure White** (`#ffffff`): Used for inverted sections, light-on-dark text, and specific button surfaces.
- **Light Gray** (`#ededed`): Light surface for inverted/light sections and subtle background tints.

## Neutrals & Text

- **White** (`#ffffff`): Primary text color on dark surfaces, maximum legibility.
- **Silver** (`#b9b9b9`): Secondary text, body copy on dark surfaces, muted descriptions, and placeholder text.
- **Medium Gray** (`#797979`): Tertiary text, metadata, timestamps, and de-emphasized content.
- **Charcoal** (`#212121`): Text on light/inverted surfaces.
- **Near Black Text** (`#0b0b0b`): Primary text on white/light button surfaces.

## Semantic

- **Error Red** (`#dd0000`): Destructive actions, validation errors, and critical warnings -- a pure, high-saturation red.
- **GPC Green** (`#37cd84`): Privacy/compliance indicator green.
- **Focus Ring Blue** (`#0052ef`): Focus ring color for accessibility, matching the interactive blue.

## Border System

- **Dark Border** (`#0b0b0b`): Primary border on dark containers -- barely visible, maintaining minimal containment.
- **Subtle Border** (`#212121`): Standard border for inputs, textareas, and card edges on dark surfaces.
- **Medium Border** (`#353535`): More visible borders for emphasized containment and dividers.
- **Light Border** (`#ffffff`): Border on inverted/light elements or buttons needing contrast separation.
- **Orange Border** (`color(display-p3 1 0.3333 0)`): Special accent border for highlighted/featured elements.
