# Typography Rules

## Font Families

- **Primary Brand**: `__hashicorpSans_96f0ca` (HashiCorp Sans), with fallback: `__hashicorpSans_Fallback_96f0ca`
- **System UI**: `system-ui, -apple-system, BlinkMacSystemFont, Segoe UI, Helvetica, Arial`

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display Hero | HashiCorp Sans | 82px (5.13rem) | 600 | 1.17 (tight) | normal | `"kern"` enabled |
| Section Heading | HashiCorp Sans | 52px (3.25rem) | 600 | 1.19 (tight) | normal | `"kern"` enabled |
| Feature Heading | HashiCorp Sans | 42px (2.63rem) | 700 | 1.19 (tight) | -0.42px | Negative tracking |
| Sub-heading | HashiCorp Sans | 34px (2.13rem) | 600–700 | 1.18 (tight) | normal | Feature blocks |
| Card Title | HashiCorp Sans | 26px (1.63rem) | 700 | 1.19 (tight) | normal | Card and panel headings |
| Small Title | HashiCorp Sans | 19px (1.19rem) | 700 | 1.21 (tight) | normal | Compact headings |
| Body Emphasis | HashiCorp Sans | 17px (1.06rem) | 600–700 | 1.18–1.35 | normal | Bold body text |
| Body Large | system-ui | 20px (1.25rem) | 400–600 | 1.50 | normal | Hero descriptions |
| Body | system-ui | 16px (1.00rem) | 400–500 | 1.63–1.69 (relaxed) | normal | Standard body text |
| Nav Link | system-ui | 15px (0.94rem) | 500 | 1.60 (relaxed) | normal | Navigation items |
| Small Body | system-ui | 14px (0.88rem) | 400–500 | 1.29–1.71 | normal | Secondary content |
| Caption | system-ui | 13px (0.81rem) | 400–500 | 1.23–1.69 | normal | Metadata, footer links |
| Uppercase Label | HashiCorp Sans | 13px (0.81rem) | 600 | 1.69 (relaxed) | 1.3px | `text-transform: uppercase` |

## Principles

- **Brand/System split**: HashiCorp Sans for headings and brand-critical text; system-ui for body, navigation, and functional text. The brand font carries the weight, system-ui carries the words.
- **Kern always on**: All HashiCorp Sans text enables OpenType `"kern"` — letterfitting is non-negotiable.
- **Tight headings**: Every heading uses 1.17–1.21 line-height, creating dense, stacked text blocks that feel infrastructural — solid, load-bearing.
- **Relaxed body**: Body text uses 1.50–1.69 line-height (notably generous), creating comfortable reading rhythm beneath the dense headings.
- **Uppercase labels as wayfinding**: 13px uppercase with 1.3px letter-spacing serves as the systematic category/section marker — always HashiCorp Sans weight 600.
