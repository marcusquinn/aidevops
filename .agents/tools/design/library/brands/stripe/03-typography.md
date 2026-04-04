<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Typography Rules

## Font Family

- **Primary**: `sohne-var`, with fallback: `SF Pro Display`
- **Monospace**: `SourceCodePro`, with fallback: `SFMono-Regular`
- **OpenType Features**: `"ss01"` enabled globally on all sohne-var text; `"tnum"` for tabular numbers on financial data and captions.

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Features | Notes |
|------|------|------|--------|-------------|----------------|----------|-------|
| Display Hero | sohne-var | 56px (3.50rem) | 300 | 1.03 (tight) | -1.4px | ss01 | Maximum size, whisper-weight authority |
| Display Large | sohne-var | 48px (3.00rem) | 300 | 1.15 (tight) | -0.96px | ss01 | Secondary hero headlines |
| Section Heading | sohne-var | 32px (2.00rem) | 300 | 1.10 (tight) | -0.64px | ss01 | Feature section titles |
| Sub-heading Large | sohne-var | 26px (1.63rem) | 300 | 1.12 (tight) | -0.26px | ss01 | Card headings, sub-sections |
| Sub-heading | sohne-var | 22px (1.38rem) | 300 | 1.10 (tight) | -0.22px | ss01 | Smaller section heads |
| Body Large | sohne-var | 18px (1.13rem) | 300 | 1.40 | normal | ss01 | Feature descriptions, intro text |
| Body | sohne-var | 16px (1.00rem) | 300-400 | 1.40 | normal | ss01 | Standard reading text |
| Button | sohne-var | 16px (1.00rem) | 400 | 1.00 (tight) | normal | ss01 | Primary button text |
| Button Small | sohne-var | 14px (0.88rem) | 400 | 1.00 (tight) | normal | ss01 | Secondary/compact buttons |
| Link | sohne-var | 14px (0.88rem) | 400 | 1.00 (tight) | normal | ss01 | Navigation links |
| Caption | sohne-var | 13px (0.81rem) | 400 | normal | normal | ss01 | Small labels, metadata |
| Caption Small | sohne-var | 12px (0.75rem) | 300-400 | 1.33-1.45 | normal | ss01 | Fine print, timestamps |
| Caption Tabular | sohne-var | 12px (0.75rem) | 300-400 | 1.33 | -0.36px | tnum | Financial data, numbers |
| Micro | sohne-var | 10px (0.63rem) | 300 | 1.15 (tight) | 0.1px | ss01 | Tiny labels, axis markers |
| Micro Tabular | sohne-var | 10px (0.63rem) | 300 | 1.15 (tight) | -0.3px | tnum | Chart data, small numbers |
| Nano | sohne-var | 8px (0.50rem) | 300 | 1.07 (tight) | normal | ss01 | Smallest labels |
| Code Body | SourceCodePro | 12px (0.75rem) | 500 | 2.00 (relaxed) | normal | -- | Code blocks, syntax |
| Code Bold | SourceCodePro | 12px (0.75rem) | 700 | 2.00 (relaxed) | normal | -- | Bold code, keywords |
| Code Label | SourceCodePro | 12px (0.75rem) | 500 | 2.00 (relaxed) | normal | uppercase | Technical labels |
| Code Micro | SourceCodePro | 9px (0.56rem) | 500 | 1.00 (tight) | normal | ss01 | Tiny code annotations |

## Principles

- **Light weight as signature**: Weight 300 at display sizes is Stripe's most distinctive typographic choice. Where others use 600-700 to command attention, Stripe uses lightness as luxury -- the text is so confident it doesn't need weight to be authoritative.
- **ss01 everywhere**: The `"ss01"` stylistic set is non-negotiable. It modifies specific glyphs (likely alternate `a`, `g`, `l` forms) to create a more geometric, contemporary feel across all sohne-var text.
- **Two OpenType modes**: `"ss01"` for display/body text, `"tnum"` for tabular numerals in financial data. These never overlap -- a number in a paragraph uses ss01, a number in a data table uses tnum.
- **Progressive tracking**: Letter-spacing tightens proportionally with size: -1.4px at 56px, -0.96px at 48px, -0.64px at 32px, -0.26px at 26px, normal at 16px and below.
- **Two-weight simplicity**: Primarily 300 (body and headings) and 400 (UI/buttons). No bold (700) in the primary font -- SourceCodePro uses 500/700 for code contrast.
