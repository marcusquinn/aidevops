# Design System: NVIDIA — Typography Rules

## Font Family

- **Primary**: `NVIDIA-EMEA`, with fallbacks: `Arial, Helvetica, sans-serif`
- **Icon Font**: `Font Awesome 6 Pro` (weight 900 for solid icons, 700 for regular)
- **Icon Sharp**: `Font Awesome 6 Sharp` (weight 300 for light icons, 400 for regular)

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display Hero | NVIDIA-EMEA | 36px (2.25rem) | 700 | 1.25 (tight) | normal | Maximum impact headlines |
| Section Heading | NVIDIA-EMEA | 24px (1.50rem) | 700 | 1.25 (tight) | normal | Section titles, card headings |
| Sub-heading | NVIDIA-EMEA | 22px (1.38rem) | 400 | 1.75 (relaxed) | normal | Feature descriptions, subtitles |
| Card Title | NVIDIA-EMEA | 20px (1.25rem) | 700 | 1.25 (tight) | normal | Card and module headings |
| Body Large | NVIDIA-EMEA | 18px (1.13rem) | 700 | 1.67 (relaxed) | normal | Emphasized body, lead paragraphs |
| Body | NVIDIA-EMEA | 16px (1.00rem) | 400 | 1.50 | normal | Standard reading text |
| Body Bold | NVIDIA-EMEA | 16px (1.00rem) | 700 | 1.50 | normal | Strong labels, nav items |
| Body Small | NVIDIA-EMEA | 15px (0.94rem) | 400 | 1.67 (relaxed) | normal | Secondary content, descriptions |
| Body Small Bold | NVIDIA-EMEA | 15px (0.94rem) | 700 | 1.50 | normal | Emphasized secondary content |
| Button Large | NVIDIA-EMEA | 18px (1.13rem) | 700 | 1.25 (tight) | normal | Primary CTA buttons |
| Button | NVIDIA-EMEA | 16px (1.00rem) | 700 | 1.25 (tight) | normal | Standard buttons |
| Button Compact | NVIDIA-EMEA | 14.4px (0.90rem) | 700 | 1.00 (tight) | 0.144px | Small/compact buttons |
| Link | NVIDIA-EMEA | 14px (0.88rem) | 700 | 1.43 | normal | Navigation links |
| Link Uppercase | NVIDIA-EMEA | 14px (0.88rem) | 700 | 1.43 | normal | `text-transform: uppercase`, nav labels |
| Caption | NVIDIA-EMEA | 14px (0.88rem) | 600 | 1.50 | normal | Metadata, timestamps |
| Caption Small | NVIDIA-EMEA | 12px (0.75rem) | 400 | 1.25 (tight) | normal | Fine print, legal |
| Micro Label | NVIDIA-EMEA | 10px (0.63rem) | 700 | 1.50 | normal | `text-transform: uppercase`, tiny badges |
| Micro | NVIDIA-EMEA | 11px (0.69rem) | 700 | 1.00 (tight) | normal | Smallest UI text |

## Principles

- **Bold as the default voice**: NVIDIA leans heavily on weight 700 for headings, buttons, links, and labels. The 400 weight is reserved for body text and descriptions -- everything else is bold, projecting confidence and authority.
- **Tight headings, relaxed body**: Heading line-height is consistently 1.25 (tight), while body text relaxes to 1.50-1.67. This contrast creates visual density at the top of content blocks and comfortable readability in paragraphs.
- **Uppercase for navigation**: Link labels use `text-transform: uppercase` with weight 700, creating a navigation voice that reads like hardware specification labels.
- **No decorative tracking**: Letter-spacing is normal throughout, except for compact buttons (0.144px). The font itself carries the industrial character without manipulation.
