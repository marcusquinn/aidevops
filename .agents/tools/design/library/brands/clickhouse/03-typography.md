# Typography Rules

## Font Family

- **Primary**: `Inter` (Next.js optimized variant `__Inter_d1b8ee`)
- **Secondary Display**: `Basier` (`__basier_a58b65`), with fallbacks: `Arial, Helvetica`
- **Code**: `Inconsolata` (`__Inconsolata_a25f62`)

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display Mega | Inter | 96px (6rem) | 900 | 1.00 (tight) | normal | Maximum impact, extra-heavy |
| Display / Hero | Inter | 72px (4.5rem) | 700 | 1.00 (tight) | normal | Section hero titles |
| Feature Heading | Basier | 36px (2.25rem) | 600 | 1.30 (tight) | normal | Feature section anchors |
| Sub-heading | Inter / Basier | 24px (1.5rem) | 600–700 | 1.17–1.38 | normal | Card headings |
| Feature Title | Inter / Basier | 20px (1.25rem) | 600–700 | 1.40 | normal | Small feature titles |
| Body Large | Inter | 18px (1.13rem) | 400–700 | 1.56 | normal | Intro paragraphs, button text |
| Body / Button | Inter | 16px (1rem) | 400–700 | 1.50 | normal | Standard body, nav, buttons |
| Caption | Inter | 14px (0.88rem) | 400–700 | 1.43 | normal | Metadata, descriptions, links |
| Uppercase Label | Inter | 14px (0.88rem) | 600 | 1.43 | 1.4px | Section overlines, wide-tracked |
| Code | Inconsolata | 16px (1rem) | 600 | 1.50 | normal | Code blocks, commands |
| Small | Inter | 12px (0.75rem) | 500 | 1.33 | normal | Smallest text |
| Micro | Inter | 11.2px (0.7rem) | 500 | 1.79 (relaxed) | normal | Tags, tiny labels |

## Principles

- **Weight 900 is the weapon**: The display headline uses Inter Black (900) — a weight most sites never touch. Combined with 96px size, this creates text with a physical, almost architectural presence.
- **Full weight spectrum**: The system uses 400, 500, 600, 700, and 900 — covering the full gamut. Weight IS hierarchy.
- **Uppercase with maximum tracking**: Section overlines use 1.4px letter-spacing — wider than most systems — creating bold structural labels that stand out against the dense dark background.
- **Dual sans-serif**: Inter handles display and body; Basier handles feature section headings at 600 weight. This creates a subtle personality shift between "data/performance" (Inter) and "product/feature" (Basier) contexts.
