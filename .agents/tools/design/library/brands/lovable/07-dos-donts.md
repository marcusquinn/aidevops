# Design System: Lovable — Do's and Don'ts

## Do

- Use the warm cream background (`#f7f4ed`) as the page foundation — it's the brand's signature warmth
- Use Camera Plain Variable at display sizes with negative letter-spacing (-0.9px to -1.5px)
- Derive all grays from `#1c1c1c` at varying opacity levels for tonal unity
- Use the inset shadow technique on dark buttons for tactile depth
- Use `#eceae4` borders instead of shadows for card containment
- Keep the weight system narrow: 400 for body/UI, 600 for headings
- Use full-pill radius (9999px) only for action pills and icon buttons
- Apply opacity 0.8 on active states for responsive tactile feedback

## Don't

- Don't use pure white (`#ffffff`) as a page background — the cream is intentional
- Don't use heavy box-shadows for cards — borders are the containment mechanism
- Don't introduce saturated accent colors — the palette is intentionally warm-neutral
- Don't use weight 700 (bold) — 600 is the maximum weight in the system
- Don't apply 9999px radius on rectangular buttons — pills are for icon/action toggles
- Don't use sharp focus outlines — the system uses soft shadow-based focus indicators
- Don't mix border styles — `#eceae4` for passive, `rgba(28,28,28,0.4)` for interactive
- Don't increase letter-spacing on headings — Camera Plain is designed to run tight at scale
