<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Startup Minimal — Layout Principles

## Spacing Scale (4px base unit)

| Token | Value | Usage |
|-------|-------|-------|
| space-0.5 | 2px | Micro adjustments, border offsets |
| space-1 | 4px | Tight inline gaps |
| space-2 | 8px | Input padding, compact gaps |
| space-3 | 12px | Component internal padding |
| space-4 | 16px | Default gaps, card internal spacing |
| space-5 | 20px | Small section gaps |
| space-6 | 24px | Card padding, form groups |
| space-8 | 32px | Section gaps |
| space-10 | 40px | Inter-section spacing |
| space-12 | 48px | Major section breaks |
| space-16 | 64px | Page sections |
| space-20 | 80px | Hero padding |

## Grid

| Property | Value |
|----------|-------|
| Columns | 12 |
| Max container | 1200px, centered |
| Narrow container | 680px (docs, articles, settings) |

## Breakpoints

| Name | Width | Columns | Gutter |
|------|-------|---------|--------|
| Mobile | 0–639px | 4 | 16px |
| Tablet | 640–1023px | 8 | 20px |
| Desktop | 1024–1199px | 12 | 24px |
| Wide | 1200px+ | 12 | 24px |

## Whitespace Philosophy

Space is information. Tight grouping signals relationship; open gaps signal separation. The 4px grid is the only source of truth — no arbitrary values. Every margin and padding snaps to the grid.

## Border Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| radius-sm | 4px | Small badges, pills, inline tags |
| radius-md | 6px | Buttons, inputs, default |
| radius-lg | 8px | Cards, containers, modals |
| radius-full | 9999px | Avatars, status indicators |
