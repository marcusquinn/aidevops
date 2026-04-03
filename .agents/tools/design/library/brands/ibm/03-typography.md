# IBM Design: Typography Rules

## Font Family

- **Primary**: `IBM Plex Sans`, with fallbacks: `Helvetica Neue, Arial, sans-serif`
- **Monospace**: `IBM Plex Mono`, with fallbacks: `Menlo, Courier, monospace`
- **Serif** (limited use): `IBM Plex Serif`, for editorial/expressive contexts
- **Icon Font**: `ibm_icons` — proprietary icon glyphs at 20px

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display 01 | IBM Plex Sans | 60px (3.75rem) | 300 (Light) | 1.17 (70px) | 0 | Maximum impact, light weight for elegance |
| Display 02 | IBM Plex Sans | 48px (3.00rem) | 300 (Light) | 1.17 (56px) | 0 | Secondary hero, responsive fallback |
| Heading 01 | IBM Plex Sans | 42px (2.63rem) | 300 (Light) | 1.19 (50px) | 0 | Expressive heading |
| Heading 02 | IBM Plex Sans | 32px (2.00rem) | 400 (Regular) | 1.25 (40px) | 0 | Section headings |
| Heading 03 | IBM Plex Sans | 24px (1.50rem) | 400 (Regular) | 1.33 (32px) | 0 | Sub-section titles |
| Heading 04 | IBM Plex Sans | 20px (1.25rem) | 600 (Semibold) | 1.40 (28px) | 0 | Card titles, feature headers |
| Heading 05 | IBM Plex Sans | 20px (1.25rem) | 400 (Regular) | 1.40 (28px) | 0 | Lighter card headings |
| Body Long 01 | IBM Plex Sans | 16px (1.00rem) | 400 (Regular) | 1.50 (24px) | 0 | Standard reading text |
| Body Long 02 | IBM Plex Sans | 16px (1.00rem) | 600 (Semibold) | 1.50 (24px) | 0 | Emphasized body, labels |
| Body Short 01 | IBM Plex Sans | 14px (0.88rem) | 400 (Regular) | 1.29 (18px) | 0.16px | Compact body, captions |
| Body Short 02 | IBM Plex Sans | 14px (0.88rem) | 600 (Semibold) | 1.29 (18px) | 0.16px | Bold captions, nav items |
| Caption 01 | IBM Plex Sans | 12px (0.75rem) | 400 (Regular) | 1.33 (16px) | 0.32px | Metadata, timestamps |
| Code 01 | IBM Plex Mono | 14px (0.88rem) | 400 (Regular) | 1.43 (20px) | 0.16px | Inline code, terminal |
| Code 02 | IBM Plex Mono | 16px (1.00rem) | 400 (Regular) | 1.50 (24px) | 0 | Code blocks |
| Mono Display | IBM Plex Mono | 42px (2.63rem) | 400 (Regular) | 1.19 (50px) | 0 | Hero mono decorative |

## Principles

- **Light weight at display sizes**: Carbon's expressive type set uses weight 300 (Light) at 42px+. This creates a distinctive tension — the content speaks with corporate authority while the letterforms whisper with typographic lightness.
- **Micro-tracking at small sizes**: 0.16px letter-spacing at 14px and 0.32px at 12px. These seemingly negligible values are Carbon's secret weapon for readability at compact sizes — they open up the tight IBM Plex letterforms just enough.
- **Three functional weights**: 300 (display/expressive), 400 (body/reading), 600 (emphasis/UI labels). Weight 700 is intentionally absent from the production type scale.
- **Productive vs. Expressive**: Productive sets use tighter line-heights (1.29) for dense UI. Expressive sets breathe more (1.40-1.50) for marketing and editorial content.
