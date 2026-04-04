<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Corporate Friendly — Layout

## Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline icon gaps |
| `--space-2` | 8px | Compact element spacing |
| `--space-3` | 12px | Input internal padding, tight groups |
| `--space-4` | 16px | Standard gap, list item spacing |
| `--space-5` | 24px | Card internal padding, form gaps |
| `--space-6` | 32px | Card padding, section internal spacing |
| `--space-7` | 48px | Section separation |
| `--space-8` | 64px | Major section breaks |
| `--space-9` | 80px | Hero padding, large breaks |
| `--space-10` | 120px | Page-level separation |

## Grid

- 12-column grid, 24px gutter
- Flex and CSS Grid for layout
- Common patterns: 2-column (50/50), 3-column (33/33/33), sidebar (30/70)
- Content never bleeds to viewport edge — minimum 20px padding always

## Container Widths

| Breakpoint | Container | Padding |
|-----------|-----------|---------|
| ≥1280px | 1200px | auto (centred) |
| 1024–1279px | 100% | 48px per side |
| 768–1023px | 100% | 32px per side |
| <768px | 100% | 20px per side |

## Whitespace Philosophy

Whitespace communicates care. Generous spacing between sections (48–80px) gives users breathing room and reduces cognitive load. Cards use 28–32px internal padding. Form fields are spaced 24px apart. The design should feel open and inviting — never cramped, never overwhelming.

## Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 6px | Tags, small badges |
| `--radius-md` | 12px | Buttons, inputs |
| `--radius-lg` | 16px | Cards, containers |
| `--radius-xl` | 20px | Feature sections, hero elements |
| `--radius-full` | 9999px | Avatars, pills, toggles |
