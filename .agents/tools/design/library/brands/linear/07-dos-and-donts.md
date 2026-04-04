<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Linear — Do's and Don'ts

## Do

- Use Inter Variable with `"cv01", "ss03"` on ALL text — these features are fundamental to Linear's typeface identity
- Use weight 510 as your default emphasis weight — it's Linear's signature between-weight
- Apply aggressive negative letter-spacing at display sizes (-1.584px at 72px, -1.056px at 48px)
- Build on near-black backgrounds: `#08090a` for marketing, `#0f1011` for panels, `#191a1b` for elevated surfaces
- Use semi-transparent white borders (`rgba(255,255,255,0.05)` to `rgba(255,255,255,0.08)`) instead of solid dark borders
- Keep button backgrounds nearly transparent: `rgba(255,255,255,0.02)` to `rgba(255,255,255,0.05)`
- Reserve brand indigo (`#5e6ad2` / `#7170ff`) for primary CTAs and interactive accents only
- Use `#f7f8f8` for primary text — not pure `#ffffff`, which would be too harsh
- Apply the luminance stacking model: deeper = darker bg, elevated = slightly lighter bg

## Don't

- Don't use pure white (`#ffffff`) as primary text — `#f7f8f8` prevents eye strain
- Don't use solid colored backgrounds for buttons — transparency is the system (rgba white at 0.02–0.05)
- Don't apply the brand indigo decoratively — it's reserved for interactive/CTA elements only
- Don't use positive letter-spacing on display text — Inter at large sizes always runs negative
- Don't use visible/opaque borders on dark backgrounds — borders should be whisper-thin semi-transparent white
- Don't skip the OpenType features (`"cv01", "ss03"`) — without them, it's generic Inter, not Linear's Inter
- Don't use weight 700 (bold) — Linear's maximum weight is 590, with 510 as the workhorse
- Don't introduce warm colors into the UI chrome — the palette is cool gray with blue-violet accent only
- Don't use drop shadows for elevation on dark surfaces — use background luminance stepping instead
