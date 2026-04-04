<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Typography Rules

## Font Families

- **Display**: `Degular Display` -- wide geometric display face for hero headlines
- **Primary**: `Inter`, with fallbacks: `Helvetica, Arial`
- **Editorial**: `GT Alpina` -- thin-weight serif for editorial moments
- **System**: `Arial` -- fallback for form elements and system UI

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display Hero XL | Degular Display | 80px (5.00rem) | 500 | 0.90 (tight) | normal | Maximum impact, compressed block |
| Display Hero | Degular Display | 56px (3.50rem) | 500 | 0.90-1.10 (tight) | 0-1.12px | Primary hero headlines |
| Display Hero SM | Degular Display | 40px (2.50rem) | 500 | 0.90 (tight) | normal | Smaller hero variant |
| Display Button | Degular Display | 24px (1.50rem) | 600 | 1.00 (tight) | 1px | Large CTA button text |
| Section Heading | Inter | 48px (3.00rem) | 500 | 1.04 (tight) | normal | Major section titles |
| Editorial Heading | GT Alpina | 48px (3.00rem) | 250 | normal | -1.92px | Thin editorial headlines |
| Editorial Sub | GT Alpina | 40px (2.50rem) | 300 | 1.08 (tight) | -1.6px | Editorial subheadings |
| Sub-heading LG | Inter | 36px (2.25rem) | 500 | normal | -1px | Large sub-sections |
| Sub-heading | Inter | 32px (2.00rem) | 400 | 1.25 (tight) | normal | Standard sub-sections |
| Sub-heading MD | Inter | 28px (1.75rem) | 500 | normal | normal | Medium sub-headings |
| Card Title | Inter | 24px (1.50rem) | 600 | normal | -0.48px | Card headings |
| Body Large | Inter | 20px (1.25rem) | 400-500 | 1.00-1.20 (tight) | -0.2px | Feature descriptions |
| Body Emphasis | Inter | 18px (1.13rem) | 600 | 1.00 (tight) | normal | Emphasized body text |
| Body | Inter | 16px (1.00rem) | 400-500 | 1.20-1.25 | -0.16px | Standard reading text |
| Body Semibold | Inter | 16px (1.00rem) | 600 | 1.16 (tight) | normal | Strong labels |
| Button | Inter | 16px (1.00rem) | 600 | normal | normal | Standard buttons |
| Button SM | Inter | 14px (0.88rem) | 600 | normal | normal | Small buttons |
| Caption | Inter | 14px (0.88rem) | 500 | 1.25-1.43 | normal | Labels, metadata |
| Caption Upper | Inter | 14px (0.88rem) | 600 | normal | 0.5px | Uppercase section labels |
| Micro | Inter | 12px (0.75rem) | 600 | 0.90-1.33 | 0.5px | Tiny labels, often uppercase |
| Micro SM | Inter | 13px (0.81rem) | 500 | 1.00-1.54 | normal | Small metadata text |

## Principles

- **Three-font system, clear roles**: Degular Display commands attention at hero scale only. Inter handles everything functional. GT Alpina adds editorial warmth sparingly.
- **Compressed display**: Degular at 0.90 line-height creates vertically compressed headline blocks that feel modern and architectural.
- **Weight as hierarchy signal**: Inter uses 400 (reading), 500 (navigation/emphasis), 600 (headings/CTAs). Degular uses 500 (display) and 600 (buttons).
- **Uppercase for labels**: Section labels (like "01 / Colors") and small categorization use `text-transform: uppercase` with 0.5px letter-spacing.
- **Negative tracking for elegance**: GT Alpina uses -1.6px to -1.92px letter-spacing for its thin-weight editorial headlines.
