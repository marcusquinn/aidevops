<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Raycast — Typography Rules

## Font Family

- **Primary**: `Inter` — humanist sans-serif, used everywhere. Fallbacks: `Inter Fallback`, system sans-serif
- **System**: `SF Pro Text` — Apple system font for select macOS-native UI elements. Fallbacks: `SF Pro Icons`, `Inter`, `Inter Fallback`
- **Monospace**: `GeistMono` — Vercel's monospace font for code elements. Fallbacks: `ui-monospace`, `SFMono-Regular`, `Roboto Mono`, `Menlo`, `Monaco`
- **OpenType features**: `calt`, `kern`, `liga`, `ss03` enabled globally; `ss02`, `ss08` on display text; `liga` disabled (`"liga" 0`) on hero headings

## Hierarchy

| Role | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|--------|-------------|----------------|-------|
| Display Hero | 64px | 600 | 1.10 | 0px | OpenType: liga 0, ss02, ss08 |
| Section Display | 56px | 400 | 1.17 | 0.2px | OpenType: calt, kern, liga, ss03 |
| Section Heading | 24px | 500 | normal | 0.2px | OpenType: calt, kern, liga, ss03 |
| Card Heading | 22px | 400 | 1.15 | 0px | OpenType: calt, kern, liga, ss03 |
| Sub-heading | 20px | 500 | 1.60 | 0.2px | Relaxed line-height for readability |
| Body Large | 18px | 400 | 1.15 | 0.2px | OpenType: calt, kern, liga, ss03 |
| Body | 16px | 500 | 1.60 | 0.2px | Primary body text, relaxed rhythm |
| Body Tight | 16px | 400 | 1.15 | 0.1px | UI labels, compact contexts |
| Button | 16px | 600 | 1.15 | 0.3px | Semibold, slightly wider tracking |
| Nav Link | 16px | 500 | 1.40 | 0.3px | Links in navigation |
| Caption | 14px | 500 | 1.14 | 0.2px | Small labels, metadata |
| Caption Bold | 14px | 600 | 1.40 | 0px | Emphasized captions |
| Small | 12px | 600 | 1.33 | 0px | Badges, tags, micro-labels |
| Small Link | 12px | 400 | 1.50 | 0.4px | Footer links, fine print |
| Code | 14px (GeistMono) | 500 | 1.60 | 0.3px | Code blocks, technical content |
| Code Small | 12px (GeistMono) | 400 | 1.60 | 0.2px | Inline code, terminal output |

## Principles

- **Positive tracking on dark**: Unlike most dark UIs that use tight or neutral letter-spacing, Raycast applies +0.2px to +0.4px — creating an airy, readable feel that compensates for the dark background
- **Weight 500 as baseline**: Most body text uses medium weight (500), not regular (400) — subtle extra heft improves legibility on dark surfaces
- **Display restraint**: Hero text at 64px/600 is confident but not oversized — Raycast avoids typographic spectacle in favor of functional elegance
- **OpenType everywhere**: `ss03` (stylistic set 3) is enabled globally across Inter, giving the typeface a slightly more geometric, tool-like quality
