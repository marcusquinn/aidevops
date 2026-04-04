<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Design: Color Palette & Roles

## Primary

- **IBM Blue 60** (`#0f62fe`): The singular interactive color. Primary buttons, links, focus states, active indicators. This is the only chromatic hue in the core UI palette.
- **White** (`#ffffff`): Page background, card surfaces, button text on blue, `--cds-background`.
- **Gray 100** (`#161616`): Primary text, headings, dark surface backgrounds, nav bar, footer. `--cds-text-primary`.

## Neutral Scale (Gray Family)

- **Gray 100** (`#161616`): Primary text, headings, dark UI chrome, footer background.
- **Gray 90** (`#262626`): Secondary dark surfaces, hover states on dark backgrounds.
- **Gray 80** (`#393939`): Tertiary dark, active states.
- **Gray 70** (`#525252`): Secondary text, helper text, descriptions. `--cds-text-secondary`.
- **Gray 60** (`#6f6f6f`): Placeholder text, disabled text.
- **Gray 50** (`#8d8d8d`): Disabled icons, muted labels.
- **Gray 30** (`#c6c6c6`): Borders, divider lines, input bottom-borders. `--cds-border-subtle`.
- **Gray 20** (`#e0e0e0`): Subtle borders, card outlines.
- **Gray 10** (`#f4f4f4`): Secondary surface background, card fills, alternating rows. `--cds-layer-01`.
- **Gray 10 Hover** (`#e8e8e8`): Hover state for Gray 10 surfaces.

## Interactive

- **Blue 60** (`#0f62fe`): Primary interactive — buttons, links, focus. `--cds-link-primary`, `--cds-button-primary`.
- **Blue 70** (`#0043ce`): Link hover state. `--cds-link-primary-hover`.
- **Blue 80** (`#002d9c`): Active/pressed state for blue elements.
- **Blue 10** (`#edf5ff`): Blue tint surface, selected row background.
- **Focus Blue** (`#0f62fe`): `--cds-focus` — 2px inset border on focused elements.
- **Focus Inset** (`#ffffff`): `--cds-focus-inset` — white inner ring for focus on dark backgrounds.

## Support & Status

- **Red 60** (`#da1e28`): Error, danger. `--cds-support-error`.
- **Green 50** (`#24a148`): Success. `--cds-support-success`.
- **Yellow 30** (`#f1c21b`): Warning. `--cds-support-warning`.
- **Blue 60** (`#0f62fe`): Informational. `--cds-support-info`.

## Dark Theme (Gray 100 Theme)

- **Background**: Gray 100 (`#161616`). `--cds-background`.
- **Layer 01**: Gray 90 (`#262626`). Card and container surfaces.
- **Layer 02**: Gray 80 (`#393939`). Elevated surfaces.
- **Text Primary**: Gray 10 (`#f4f4f4`). `--cds-text-primary`.
- **Text Secondary**: Gray 30 (`#c6c6c6`). `--cds-text-secondary`.
- **Border Subtle**: Gray 80 (`#393939`). `--cds-border-subtle`.
- **Interactive**: Blue 40 (`#78a9ff`). Links and interactive elements shift lighter for contrast.
