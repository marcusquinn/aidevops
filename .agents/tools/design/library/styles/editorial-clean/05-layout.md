<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# 5. Layout Principles

## Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline icon gaps |
| `--space-2` | 8px | Tight component spacing |
| `--space-3` | 12px | Caption spacing, byline gaps |
| `--space-4` | 16px | Standard component padding |
| `--space-5` | 24px | Card padding, pull quote indent |
| `--space-6` | 32px | Form field spacing |
| `--space-7` | 48px | Section breaks, article card gaps |
| `--space-8` | 64px | Major section separation |
| `--space-9` | 96px | Hero vertical padding |
| `--space-10` | 128px | Page-level top margin |

## Content Width

| Element | Max Width | Behaviour |
|---------|-----------|-----------|
| Body text | 680px | Centred, the primary content column |
| Images | 900px | Can exceed text column for visual impact |
| Full-bleed images | 100vw | Edge-to-edge, break out of container |
| Code blocks | 780px | Slightly wider than text for readability |
| Overall container | 1080px | Maximum page width including margins |

## Grid

- Single-column layout for articles (680px content)
- Two-column grid for index/listing pages (article cards)
- No sidebar during article reading — distraction-free
- Optional: sticky table of contents in left margin on wide screens (≥1280px)

## Whitespace Philosophy

Whitespace defines this system. Every element breathes. When in doubt, add more — it always improves readability.

## Border-Radius Scale

Minimal rounding — editorial aesthetic favours clean, near-square edges.

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 2px | Tags, inline code |
| `--radius-md` | 4px | Buttons, inputs, code blocks |
| `--radius-lg` | 8px | Newsletter signup cards |
| `--radius-full` | 9999px | Author avatars |
