<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Composio — Typography Rules

## Font Family

- **Primary**: `abcDiatype`, with fallbacks: `abcDiatype Fallback, ui-sans-serif, system-ui, Apple Color Emoji, Segoe UI Emoji, Segoe UI Symbol, Noto Color Emoji`
- **Monospace**: `JetBrains Mono`, with fallbacks: `JetBrains Mono Fallback, ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, Liberation Mono, Courier New`
- **System Monospace** (fallback): `Menlo`, `monospace` for smallest inline code

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display / Hero | abcDiatype | 64px (4rem) | 400 | 0.87 (ultra-tight) | normal | Massive, compressed headings |
| Section Heading | abcDiatype | 48px (3rem) | 400 | 1.00 (tight) | normal | Major feature section titles |
| Sub-heading Large | abcDiatype | 40px (2.5rem) | 400 | 1.00 (tight) | normal | Secondary section markers |
| Sub-heading | abcDiatype | 28px (1.75rem) | 400 | 1.20 (tight) | normal | Card titles, feature names |
| Card Title | abcDiatype | 24px (1.5rem) | 500 | 1.20 (tight) | normal | Medium-emphasis card headings |
| Feature Label | abcDiatype | 20px (1.25rem) | 500 | 1.20 (tight) | normal | Smaller card titles, labels |
| Body Large | abcDiatype | 18px (1.125rem) | 400 | 1.20 (tight) | normal | Intro paragraphs |
| Body / Button | abcDiatype | 16px (1rem) | 400 | 1.50 | normal | Standard body text, nav links, buttons |
| Body Small | abcDiatype | 15px (0.94rem) | 400 | 1.63 (relaxed) | normal | Longer-form body text |
| Caption | abcDiatype | 14px (0.875rem) | 400 | 1.63 (relaxed) | normal | Descriptions, metadata |
| Label | abcDiatype | 13px (0.81rem) | 500 | 1.50 | normal | UI labels, badges |
| Tag / Overline | abcDiatype | 12px (0.75rem) | 500 | 1.00 (tight) | 0.3px | Uppercase overline labels |
| Micro | abcDiatype | 12px (0.75rem) | 400 | 1.00 (tight) | 0.3px | Smallest sans-serif text |
| Code Body | JetBrains Mono | 16px (1rem) | 400 | 1.50 | -0.32px | Inline code, terminal output |
| Code Small | JetBrains Mono | 14px (0.875rem) | 400 | 1.50 | -0.28px | Code snippets, technical labels |
| Code Caption | JetBrains Mono | 12px (0.75rem) | 400 | 1.50 | -0.28px | Small code references |
| Code Overline | JetBrains Mono | 14px (0.875rem) | 400 | 1.43 | 0.7px | Uppercase technical labels |
| Code Micro | JetBrains Mono | 11px (0.69rem) | 400 | 1.33 | 0.55px | Tiny uppercase code tags |
| Code Nano | JetBrains Mono | 9-10px | 400 | 1.33 | 0.45-0.5px | Smallest monospace text |

## Principles

- **Compression creates authority**: Heading line-heights are drastically tight (0.87-1.0), making large text feel dense and commanding rather than airy and decorative.
- **Dual personality**: abcDiatype carries the marketing voice — geometric, precise, friendly. JetBrains Mono carries the technical voice — credible, functional, familiar to developers.
- **Weight restraint**: Almost everything is weight 400 (regular). Weight 500 (medium) is reserved for small labels, badges, and select card titles. Weight 700 (bold) appears only in microscopic system-monospace contexts.
- **Negative letter-spacing on code**: JetBrains Mono uses negative letter-spacing (-0.28px to -0.98px) for dense, compact code blocks that feel like a real IDE.
- **Uppercase is earned**: The `uppercase` + `letter-spacing` treatment is reserved exclusively for tiny overline labels and technical tags — never for headings.
