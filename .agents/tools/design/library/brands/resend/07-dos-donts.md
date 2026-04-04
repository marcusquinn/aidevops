# Design System: Resend — Do's and Don'ts

## Do

- Use pure black (`#000000`) as the page background — the void is the canvas
- Apply frost borders (`rgba(214, 235, 253, 0.19)`) for all structural lines — they're the blue-tinted signature
- Use Domaine Display ONLY for hero headings (96px), ABC Favorit for section headings, Inter for everything else
- Enable OpenType `"ss01"`, `"ss04"`, `"ss11"` on Domaine and ABC Favorit text
- Apply pill radius (9999px) to primary CTAs and tags
- Use the multi-color accent scale (orange/green/blue/yellow/red) with opacity variants for context-specific highlighting
- Keep shadows at ring level (`0px 0px 0px 1px`) — on black, traditional shadows don't work
- Use +0.35px letter-spacing on ABC Favorit nav links — the only positive tracking

## Don't

- Don't lighten the background above `#000000` — the pure black void is non-negotiable
- Don't use neutral gray borders — all borders must have the frost blue tint
- Don't apply Domaine Display to body text — it's a display-only serif
- Don't mix accent colors in the same component — each feature gets one accent color
- Don't use box-shadow for elevation on the dark background — use frost borders instead
- Don't skip the OpenType stylistic sets — they define the typographic character
- Don't use negative letter-spacing on nav links — ABC Favorit nav uses positive +0.35px
- Don't make buttons opaque on dark — transparency with frost border is the pattern
