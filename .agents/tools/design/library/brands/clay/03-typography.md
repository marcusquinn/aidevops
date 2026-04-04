<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Clay Design System: Typography Rules

## Font Families

- **Primary**: `Roobert`, fallback: `Arial`
- **Monospace**: `Space Mono`
- **OpenType Features**: `"ss01"`, `"ss03"`, `"ss10"`, `"ss11"`, `"ss12"` on all Roobert text (display uses all 5; body/UI uses `"ss03"`, `"ss10"`, `"ss11"`, `"ss12"`)

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display Hero | Roobert | 80px (5.00rem) | 600 | 1.00 (tight) | -3.2px | All 5 stylistic sets |
| Display Secondary | Roobert | 60px (3.75rem) | 600 | 1.00 (tight) | -2.4px | All 5 stylistic sets |
| Section Heading | Roobert | 44px (2.75rem) | 600 | 1.10 (tight) | -0.88px to -1.32px | All 5 stylistic sets |
| Card Heading | Roobert | 32px (2.00rem) | 600 | 1.10 (tight) | -0.64px | All 5 stylistic sets |
| Feature Title | Roobert | 20px (1.25rem) | 600 | 1.40 | -0.4px | All 5 stylistic sets |
| Sub-heading | Roobert | 20px (1.25rem) | 500 | 1.50 | -0.16px | 4 stylistic sets (no ss01) |
| Body Large | Roobert | 20px (1.25rem) | 400 | 1.40 | normal | 4 stylistic sets |
| Body | Roobert | 18px (1.13rem) | 400 | 1.60 (relaxed) | -0.36px | 4 stylistic sets |
| Body Standard | Roobert | 16px (1.00rem) | 400 | 1.50 | normal | 4 stylistic sets |
| Body Medium | Roobert | 16px (1.00rem) | 500 | 1.20–1.40 | -0.16px to -0.32px | 4–5 stylistic sets |
| Button | Roobert | 16px (1.00rem) | 500 | 1.50 | -0.16px | 4 stylistic sets |
| Button Large | Roobert | 24px (1.50rem) | 400 | 1.50 | normal | 4 stylistic sets |
| Button Small | Roobert | 12.8px (0.80rem) | 500 | 1.50 | -0.128px | 4 stylistic sets |
| Nav Link | Roobert | 15px (0.94rem) | 500 | 1.60 (relaxed) | normal | 4 stylistic sets |
| Caption | Roobert | 14px (0.88rem) | 400 | 1.50–1.60 | -0.14px | 4 stylistic sets |
| Small | Roobert | 12px (0.75rem) | 400 | 1.50 | normal | 4 stylistic sets |
| Uppercase Label | Roobert | 12px (0.75rem) | 600 | 1.20 (tight) | 1.08px | `text-transform: uppercase`, 4 sets |
| Badge | Roobert | 9.6px | 600 | — | — | Pill badges |

## Principles

- **Five stylistic sets as identity**: The combination of `"ss01"`, `"ss03"`, `"ss10"`, `"ss11"`, `"ss12"` on Roobert creates a distinctive typographic personality. `ss01` is reserved for headings and emphasis — body text omits it, creating a subtle hierarchy through glyph variation.
- **Aggressive display compression**: -3.2px at 80px, -2.4px at 60px — the most compressed display tracking alongside the most generous body spacing (1.60 line-height), creating dramatic contrast.
- **Weight 600 for headings, 500 for UI, 400 for body**: Clean three-tier system where each weight has a strict role.
- **Uppercase labels with positive tracking**: 12px uppercase at 1.08px letter-spacing creates the systematic wayfinding pattern.
