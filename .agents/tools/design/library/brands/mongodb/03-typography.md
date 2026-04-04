# Design System: MongoDB — Typography Rules

## Font Families

- **Display Serif**: `MongoDB Value Serif` — editorial hero headlines
- **Body / UI**: `Euclid Circular A` — geometric sans-serif workhorse
- **Code / Labels**: `Source Code Pro` — monospace with uppercase label treatments
- **Fallbacks**: `Akzidenz-Grotesk Std` (with CJK: Noto Sans KR/SC/JP), `Times`, `Arial`, `system-ui`

## Hierarchy

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display Hero | MongoDB Value Serif | 96px (6.00rem) | 400 | 1.20 (tight) | normal | Serif authority |
| Display Secondary | MongoDB Value Serif | 64px (4.00rem) | 400 | 1.00 (tight) | normal | Serif sub-hero |
| Section Heading | Euclid Circular A | 36px (2.25rem) | 500 | 1.33 | normal | Geometric precision |
| Sub-heading | Euclid Circular A | 24px (1.50rem) | 500 | 1.33 | normal | Feature titles |
| Body Large | Euclid Circular A | 20px (1.25rem) | 400 | 1.60 (relaxed) | normal | Introductions |
| Body | Euclid Circular A | 18px (1.13rem) | 400 | 1.33 | normal | Standard body |
| Body Light | Euclid Circular A | 16px (1.00rem) | 300 | 1.50–2.00 | normal | Light-weight reading text |
| Nav / UI | Euclid Circular A | 16px (1.00rem) | 500 | 1.00–1.88 | 0.16px | Navigation, emphasized |
| Body Bold | Euclid Circular A | 15px (0.94rem) | 700 | 1.50 | normal | Strong emphasis |
| Button | Euclid Circular A | 13.5px–16px | 500–700 | 1.00 | 0.135px–0.9px | CTA labels |
| Caption | Euclid Circular A | 14px (0.88rem) | 400 | 1.71 (relaxed) | normal | Metadata |
| Small | Euclid Circular A | 11px (0.69rem) | 600 | 1.82 (relaxed) | 0.2px | Tags, annotations |
| Code Heading | Source Code Pro | 40px (2.50rem) | 400 | 1.60 (relaxed) | normal | Code showcase titles |
| Code Body | Source Code Pro | 16px (1.00rem) | 400 | 1.50 | normal | Code blocks |
| Code Label | Source Code Pro | 14px (0.88rem) | 400–500 | 1.14 (tight) | 1px–2px | `text-transform: uppercase` |
| Code Micro | Source Code Pro | 9px (0.56rem) | 600 | 2.67 (relaxed) | 2.5px | `text-transform: uppercase` |

## Principles

- **Serif for authority**: MongoDB Value Serif at hero scale creates an editorial presence unusual in tech — it communicates that MongoDB is an institution, not a startup.
- **Weight 300 as body default**: Euclid Circular A uses light (300) for body text, creating an airy reading experience that contrasts with the dense, dark backgrounds.
- **Wide-tracked monospace labels**: Source Code Pro uppercase at 1px–3px letter-spacing creates technical signposts that feel like database field labels — systematic, structured, classified.
- **Four-weight range**: 300 (light body) → 400 (standard) → 500 (UI/nav) → 700 (bold CTA) — a wider range than most systems, enabling fine-grained hierarchy.
