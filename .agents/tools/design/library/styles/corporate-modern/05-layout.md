<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Corporate Modern — Layout Principles

## Spacing Scale (8px grid)

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline icon gaps, tight pairs |
| `--space-2` | 8px | Compact element spacing |
| `--space-3` | 12px | Input internal padding |
| `--space-4` | 16px | Standard gap, card gap |
| `--space-5` | 24px | Card padding, form field gaps |
| `--space-6` | 32px | Section internal padding |
| `--space-7` | 48px | Section breaks |
| `--space-8` | 64px | Major section separation |
| `--space-9` | 80px | Hero vertical padding |
| `--space-10` | 120px | Page-level vertical breathing room |

## Grid

- 12-column grid, 24px gutter
- All spacing values must be multiples of 8px (4px for fine adjustments)
- Flex and CSS Grid preferred over float layouts

## Container Widths

| Breakpoint | Container | Behaviour |
|-----------|-----------|-----------|
| ≥1440px | 1280px | Centred, fixed max-width |
| 1024–1439px | 100% - 96px | Fluid with 48px side padding |
| 768–1023px | 100% - 64px | Fluid with 32px side padding |
| <768px | 100% - 40px | Fluid with 20px side padding |

## Whitespace Philosophy

Whitespace is a first-class design element. Components breathe — generous padding inside cards (24px), meaningful gaps between sections (48–80px), and never less than 16px between distinct interactive elements. Dense UI is acceptable in data tables but nowhere else.

## Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 4px | Tags, small badges |
| `--radius-md` | 8px | Buttons, inputs, small cards |
| `--radius-lg` | 12px | Cards, containers |
| `--radius-xl` | 16px | Modals, feature cards |
| `--radius-full` | 9999px | Pills, avatars, toggles |
