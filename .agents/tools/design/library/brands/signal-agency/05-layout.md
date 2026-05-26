<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency — Layout

## Grid

- Page max width: `1280px`.
- Gutter: `clamp(20px, 4vw, 56px)`.
- Desktop grid: 12 columns with 24px component gaps.
- Body measure: 56ch; ledes up to 60ch; cover dek about 40ch.
- Section head desktop: 220px index column plus main title column.

## Spacing

4px base scale: `4, 8, 12, 16, 24, 32, 48, 64, 96`. Do not invent one-off values. Increase density by changing layout, not by shrinking the scale below 4px.

## Rule hierarchy

| Weight | Use |
|--------|-----|
| 4px ink | Masthead top, footer top, strong document boundary |
| 2px ink | Action-line sandwich, critical separators |
| 1px ink | Section top, table header/body boundary, component outer border |
| 1px soft | Internal card/footer dividers, section bottom |
| 1px dotted | Tertiary rows and subtle list separation |

## Report structure

1. Sticky masthead with logo, metadata, and anchor navigation.
2. Cover with kicker, huge display title, deck, and source/system metadata.
3. Foundation sections with swatches/type/state rules.
4. Component sections with specimen plus usage notes.
5. Applied report section demonstrating real audit content.
6. Footer with system/version/type note.

## Print/PDF

Print should keep typography, rules, and evidence badges. Sticky masthead becomes static. Avoid section breaks inside major components and keep table headers readable.
