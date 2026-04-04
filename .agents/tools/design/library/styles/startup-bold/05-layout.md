<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Startup Bold — Layout Principles

## Spacing Scale (4px base unit)

| Token | Value | Usage |
|-------|-------|-------|
| space-1 | 4px | Micro adjustments, icon padding |
| space-2 | 8px | Inline gaps, tight spacing |
| space-3 | 12px | Component internal padding |
| space-4 | 16px | Default component gaps |
| space-5 | 20px | Card content spacing |
| space-6 | 24px | Form group spacing |
| space-8 | 32px | Card padding, section sub-gaps |
| space-10 | 40px | Section gaps |
| space-12 | 48px | Inter-section spacing |
| space-16 | 64px | Major section breaks |
| space-20 | 80px | Hero section padding |
| space-24 | 96px | Page section divisions |

## Grid

- 12-column grid
- Gutter: 16px (mobile), 24px (tablet), 32px (desktop)
- Max container: 1280px, centered
- Content-width variant: 768px for article/text-heavy pages

## Breakpoints

| Name | Width | Columns | Gutter |
|------|-------|---------|--------|
| Mobile | 0–639px | 4 | 16px |
| Tablet | 640–1023px | 8 | 24px |
| Desktop | 1024–1279px | 12 | 32px |
| Wide | 1280px+ | 12 | 32px |

## Whitespace Philosophy

Consistent, rhythmic spacing reinforces the grid and communicates reliability. Tight where elements are related; open where sections need separation. No arbitrary values.

## Border Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| radius-sm | 6px | Small badges, chips |
| radius-md | 12px | Buttons, inputs, default |
| radius-lg | 16px | Cards, containers |
| radius-xl | 24px | Feature cards, testimonial blocks |
| radius-full | 9999px | Avatars, status dots |
