<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Design: Do's and Don'ts

## Do

- Use IBM Plex Sans at weight 300 for display sizes (42px+) — the lightness is intentional
- Apply 0.16px letter-spacing on 14px body text and 0.32px on 12px captions
- Use 0px border-radius on buttons, inputs, cards, and tiles — rectangles are the system
- Reference `--cds-*` token names when implementing (e.g., `--cds-button-primary`, `--cds-text-primary`)
- Use background-color layering (white → gray 10 → gray 20) for depth instead of shadows
- Use bottom-border (not box) for input field indicators
- Maintain the 48px default button height and asymmetric padding for icon accommodation
- Apply Blue 60 (`#0f62fe`) as the sole accent — one blue to rule them all

## Don't

- Don't round button corners — 0px radius is the Carbon identity
- Don't use shadows on cards or tiles — flatness is the point
- Don't introduce additional accent colors — IBM's system is monochromatic + blue
- Don't use weight 700 (Bold) — the scale stops at 600 (Semibold)
- Don't add letter-spacing to display-size text — tracking is only for 14px and below
- Don't box inputs with full borders — Carbon inputs use bottom-border only
- Don't use gradient backgrounds — IBM's surfaces are flat, solid colors
- Don't deviate from the 8px spacing grid — every value should be divisible by 8 (with 2px and 4px for micro-adjustments)
