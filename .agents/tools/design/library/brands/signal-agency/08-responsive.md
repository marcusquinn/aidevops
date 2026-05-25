<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency — Responsive Behaviour

## Breakpoints

- Below 720px: collapse 12-column layouts to one column, stats to 2-up, ledgers to two columns with wrapped note/confidence rows.
- 720px and above: enable 2/3/4-column component grids.
- 900px and above: cover uses content + 360px side metadata; section headers use index + content columns.

## Mobile rules

- Reduce cover display type through clamp values; never manually set tiny fixed cover sizes.
- Keep masthead usable: metadata/navigation may wrap or become a compact menu.
- Tables can scroll horizontally only when source/evidence columns would become unreadable; otherwise stack rows with preserved labels.
- Touch targets for nav/actions should be at least 44px high.

## Desktop rules

- Maintain the 1280px max page width and generous gutters.
- Use the left index column to reinforce structure.
- Let body copy stay narrow even inside wide sections.

## Print/PDF rules

- Disable sticky positioning.
- Keep state badges, source IDs, confidence bars, and priority markers visible without hover.
- Avoid orphaned headings and split callout/card bodies.
- A4, US Letter, and slides should be generated from one canonical HTML/Markdown source.
