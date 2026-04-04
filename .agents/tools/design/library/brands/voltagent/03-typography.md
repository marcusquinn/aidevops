<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoltAgent Design System: Typography Rules

## Font Family

- **Primary (Headings)**: `system-ui`, with fallbacks: `-apple-system, Segoe UI, Roboto, Ubuntu, Cantarell, Noto Sans, Helvetica, Arial, Apple Color Emoji, Segoe UI Emoji, Segoe UI Symbol`
- **Secondary (Body/UI)**: `Inter`, with fallbacks inheriting from system-ui stack. OpenType features: `"calt", "rlig"` (contextual alternates and required ligatures)
- **Monospace (Code)**: `SFMono-Regular`, with fallbacks: `Menlo, Monaco, Consolas, Liberation Mono, Courier New, monospace`

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display / Hero | system-ui | 60px (3.75rem) | 400 | 1.00 (tight) | -0.65px | Maximum impact, compressed blocks |
| Section Heading | system-ui | 36px (2.25rem) | 400 | 1.11 (tight) | -0.9px | Tightest letter-spacing in the system |
| Sub-heading | system-ui | 24px (1.50rem) | 700 | 1.33 | -0.6px | Bold weight for emphasis at this size |
| Sub-heading Light | system-ui / Inter | 24px (1.50rem) | 300–400 | 1.33 | -0.6px | Light weight variant for softer hierarchy |
| Overline | system-ui | 20px (1.25rem) | 600 | 1.40 | 0.5px | Uppercase transform, positive letter-spacing |
| Feature Title | Inter | 20px (1.25rem) | 500–600 | 1.40 | normal | Card headings, feature names |
| Overline Small | Inter | 18px (1.13rem) | 600 | 1.56 | 0.45px | Uppercase section labels |
| Body / Button | Inter | 16px (1.00rem) | 400–600 | 1.50–1.65 | normal | Standard text, nav links, buttons |
| Nav Link | Inter | 14.45px (0.90rem) | 500 | 1.65 | normal | Navigation-specific sizing |
| Caption / Label | Inter | 14px (0.88rem) | 400–600 | 1.43–1.65 | normal | Descriptions, metadata, badge text |
| Tag / Overline Tiny | system-ui | 14px (0.88rem) | 600 | 1.43 | 2.52px | Widest letter-spacing — reserved for uppercase tags |
| Micro | Inter | 12px (0.75rem) | 400–500 | 1.33 | normal | Smallest sans-serif text |
| Code Body | SFMono-Regular | 13–14px | 400–686 | 1.23–1.43 | normal | Inline code, terminal output, variable weight for syntax |
| Code Small | SFMono-Regular | 11–12px | 400 | 1.33–1.45 | normal | Tiny code references, line numbers |
| Code Button | monospace | 13px (0.81rem) | 700 | 1.65 | normal | Copy-to-clipboard button labels |

## Principles

- **System-native authority**: Display headings use system-ui rather than a custom web font — this means the largest text renders instantly (no FOIT/FOUT) and inherits the operating system's native personality. On macOS it's SF Pro, on Windows it's Segoe UI. The design accepts this variability as a feature, not a bug.
- **Tight compression creates density**: Hero line-heights are extremely compressed (1.0) with negative letter-spacing (-0.65px to -0.9px), creating text blocks that feel like dense technical specifications rather than airy marketing copy.
- **Weight gradient, not weight contrast**: The system uses a gentle 300→400→500→600→700 weight progression. Bold (700) is reserved for sub-headings and code-button emphasis. Most body text lives at 400–500, creating subtle rather than dramatic hierarchy.
- **Uppercase is earned and wide**: When uppercase appears, it's always paired with generous letter-spacing (0.45px–2.52px), transforming dense words into spaced-out overline labels. This treatment is never applied to headings.
- **OpenType by default**: Both system-ui and Inter enable `"calt"` and `"rlig"` features, ensuring contextual character adjustments and ligature rendering throughout.
