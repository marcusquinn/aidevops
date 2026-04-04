<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Agency Creative — Typography Rules

## Font Families

| Role | Stack |
|------|-------|
| Display | `'Space Grotesk', 'Plus Jakarta Sans', system-ui, sans-serif` |
| Body | `'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif` |
| Mono | `'JetBrains Mono', 'SF Mono', monospace` |

## Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display XL | Display | 80px | 700 | 1.0 | -0.04em | Hero headlines, maximum impact |
| Display | Display | 64px | 700 | 1.05 | -0.035em | Section heroes, landing statements |
| H1 | Display | 48px | 700 | 1.1 | -0.03em | Page titles |
| H2 | Display | 36px | 600 | 1.15 | -0.02em | Section headings |
| H3 | Display | 28px | 600 | 1.2 | -0.015em | Subsection headings |
| H4 | Display | 22px | 600 | 1.25 | -0.01em | Card titles |
| Overline | Body | 13px | 600 | 1.4 | 0.12em | Category labels, section tags (UPPERCASE) |
| Body Large | Body | 18px | 400 | 1.7 | -0.006em | Lead paragraphs, introductions |
| Body | Body | 16px | 400 | 1.65 | -0.006em | Primary reading text |
| Body Small | Body | 14px | 400 | 1.5 | 0 | Captions, secondary info |
| Label | Body | 12px | 500 | 1.4 | 0.04em | Form labels, metadata |
| Code | Mono | 14px | 400 | 1.6 | 0 | Code snippets, technical details |

## Typography Principles

- Display type (Space Grotesk) is reserved for headings and hero content — never body text
- Use UPPERCASE overlines sparingly to introduce sections with category context
- Headings at 64px+ can use the gradient as a text fill (`background-clip: text`) for maximum impact
- Body text stays in Inter for readability — never sacrifice legibility for style
- Track display type tighter as it gets larger (negative letter-spacing scales with size)
