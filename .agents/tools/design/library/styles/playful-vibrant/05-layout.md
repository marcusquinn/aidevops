<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Playful Vibrant — Layout

## Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline icon gaps |
| `--space-2` | 8px | Badge padding, compact spacing |
| `--space-3` | 12px | Tag padding, tight groups |
| `--space-4` | 16px | Standard gap, list item spacing |
| `--space-5` | 24px | Card gap, form field spacing |
| `--space-6` | 32px | Card padding, section internal |
| `--space-7` | 48px | Section breaks |
| `--space-8` | 64px | Major section separation |
| `--space-9` | 80px | Hero padding |
| `--space-10` | 120px | Page-level separation |

## Grid

- 12-column grid, 24px gutter
- Common layouts: 2-column (50/50), 3-column (33/33/33), 4-column (25×4)
- Card grids use CSS Grid with `auto-fill` and `minmax(280px, 1fr)` for responsive columns
- Content alignment: centred for marketing, left-aligned for app interfaces

## Container Widths

| Breakpoint | Container | Padding |
|-----------|-----------|---------|
| ≥1440px | 1280px | auto (centred) |
| 1024–1439px | 100% | 48px per side |
| 768–1023px | 100% | 32px per side |
| <768px | 100% | 16px per side |

## Whitespace Philosophy

Bold colours and rounded shapes become chaotic without space. Sections: 48–64px breathing room; cards: 24px internal padding. Every element needs space to be understood independently.

## Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 8px | Small interactive elements |
| `--radius-md` | 12px | Nav items, compact cards |
| `--radius-lg` | 16px | Buttons, inputs |
| `--radius-xl` | 20px | Cards, containers, modals |
| `--radius-2xl` | 28px | Hero sections, feature areas |
| `--radius-full` | 9999px | Avatars, pills, badges, toggles |
