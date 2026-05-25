<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency — Depth and Elevation

## Philosophy

Signal is mostly flat. Depth comes from editorial layering: paper changes, hard rules, header strips, and metadata chrome. Avoid conventional soft shadows and glass effects.

## Depth levels

| Level | Treatment | Use |
|-------|-----------|-----|
| 0 | Paper background, no border | Body page |
| 1 | Hairline rule or dotted divider | Lists, rows, low-priority groups |
| 2 | 1px ink border, square surface | Tables, cards, stat blocks |
| 3 | Ink header strip + bordered body | Dossier cards and KPI cards |
| 4 | Hard 3-4px ink offset shadow | Signature cards only; never every panel |

## Shape

- Default radius: `0px`.
- Report containers, tables, cards, code blocks, copy buttons, buttons, source cards, and callouts must use `0px` radius.
- Tiny inline evidence/state badges may use at most `1px` radius to prevent optical harshness, but square is preferred.
- Do not use pill-shaped CTAs except tiny state pills inherited from the specimen.

## Motion and interaction

- Motion is functional and minimal: hover colour shift, focus outline, sticky nav.
- LED glow is allowed inside dark header strips only.
- Avoid springy cards, blur, parallax, confetti, or ornamental transitions.
