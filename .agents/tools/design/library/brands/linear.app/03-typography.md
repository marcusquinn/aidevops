# Design System: Linear — Typography Rules

## Font Family

- **Primary**: `Inter Variable`, with fallbacks: `SF Pro Display, -apple-system, system-ui, Segoe UI, Roboto, Oxygen, Ubuntu, Cantarell, Open Sans, Helvetica Neue`
- **Monospace**: `Berkeley Mono`, with fallbacks: `ui-monospace, SF Mono, Menlo`
- **OpenType Features**: `"cv01", "ss03"` enabled globally — cv01 provides an alternate lowercase 'a' (single-story), ss03 adjusts specific letterforms for a cleaner geometric appearance.

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display XL | Inter Variable | 72px (4.50rem) | 510 | 1.00 (tight) | -1.584px | Hero headlines, maximum impact |
| Display Large | Inter Variable | 64px (4.00rem) | 510 | 1.00 (tight) | -1.408px | Secondary hero text |
| Display | Inter Variable | 48px (3.00rem) | 510 | 1.00 (tight) | -1.056px | Section headlines |
| Heading 1 | Inter Variable | 32px (2.00rem) | 400 | 1.13 (tight) | -0.704px | Major section titles |
| Heading 2 | Inter Variable | 24px (1.50rem) | 400 | 1.33 | -0.288px | Sub-section headings |
| Heading 3 | Inter Variable | 20px (1.25rem) | 590 | 1.33 | -0.24px | Feature titles, card headers |
| Body Large | Inter Variable | 18px (1.13rem) | 400 | 1.60 (relaxed) | -0.165px | Introduction text, feature descriptions |
| Body Emphasis | Inter Variable | 17px (1.06rem) | 590 | 1.60 (relaxed) | normal | Emphasized body, sub-headings in content |
| Body | Inter Variable | 16px (1.00rem) | 400 | 1.50 | normal | Standard reading text |
| Body Medium | Inter Variable | 16px (1.00rem) | 510 | 1.50 | normal | Navigation, labels |
| Body Semibold | Inter Variable | 16px (1.00rem) | 590 | 1.50 | normal | Strong emphasis |
| Small | Inter Variable | 15px (0.94rem) | 400 | 1.60 (relaxed) | -0.165px | Secondary body text |
| Small Medium | Inter Variable | 15px (0.94rem) | 510 | 1.60 (relaxed) | -0.165px | Emphasized small text |
| Small Semibold | Inter Variable | 15px (0.94rem) | 590 | 1.60 (relaxed) | -0.165px | Strong small text |
| Small Light | Inter Variable | 15px (0.94rem) | 300 | 1.47 | -0.165px | De-emphasized body |
| Caption Large | Inter Variable | 14px (0.88rem) | 510–590 | 1.50 | -0.182px | Sub-labels, category headers |
| Caption | Inter Variable | 13px (0.81rem) | 400–510 | 1.50 | -0.13px | Metadata, timestamps |
| Label | Inter Variable | 12px (0.75rem) | 400–590 | 1.40 | normal | Button text, small labels |
| Micro | Inter Variable | 11px (0.69rem) | 510 | 1.40 | normal | Tiny labels |
| Tiny | Inter Variable | 10px (0.63rem) | 400–510 | 1.50 | -0.15px | Overline text, sometimes uppercase |
| Link Large | Inter Variable | 16px (1.00rem) | 400 | 1.50 | normal | Standard links |
| Link Medium | Inter Variable | 15px (0.94rem) | 510 | 2.67 | normal | Spaced navigation links |
| Link Small | Inter Variable | 14px (0.88rem) | 510 | 1.50 | normal | Compact links |
| Link Caption | Inter Variable | 13px (0.81rem) | 400–510 | 1.50 | -0.13px | Footer, metadata links |
| Mono Body | Berkeley Mono | 14px (0.88rem) | 400 | 1.50 | normal | Code blocks |
| Mono Caption | Berkeley Mono | 13px (0.81rem) | 400 | 1.50 | normal | Code labels |
| Mono Label | Berkeley Mono | 12px (0.75rem) | 400 | 1.40 | normal | Code metadata, sometimes uppercase |

## Principles

- **510 is the signature weight**: Linear uses Inter Variable's 510 weight (between regular 400 and medium 500) as its default emphasis weight. This creates a subtly bolded feel without the heaviness of traditional medium or semibold.
- **Compression at scale**: Display sizes use progressively tighter letter-spacing — -1.584px at 72px, -1.408px at 64px, -1.056px at 48px, -0.704px at 32px. Below 24px, spacing relaxes toward normal.
- **OpenType as identity**: `"cv01", "ss03"` aren't decorative — they transform Inter into Linear's distinctive typeface, giving it a more geometric, purposeful character.
- **Three-tier weight system**: 400 (reading), 510 (emphasis/UI), 590 (strong emphasis). The 300 weight appears only in deliberately de-emphasized contexts.
