# Design System: Sanity — Do's and Don'ts

## Do

- Use the achromatic gray scale as the foundation -- maintain pure neutral discipline with no warm/cool tinting
- Apply Electric Blue (`#0052ef`) consistently as the universal hover/active state across all interactive elements
- Use extreme negative letter-spacing (-2px to -4.48px) on display headings 48px and above
- Keep primary CTAs as full-pill shapes (99999px radius) with the coral-red (`#f36458`)
- Use IBM Plex Mono uppercase for technical labels, tags, and system metadata
- Communicate depth through surface color (dark-to-light) rather than shadows
- Maintain generous vertical section spacing (64-120px) on the dark canvas
- Use `"cv01", "cv11", "cv12", "cv13", "ss07"` OpenType features for display typography

## Don't

- Don't introduce warm or cool color tints to the neutral scale -- Sanity's grays are pure achromatic
- Don't use drop shadows for elevation -- dark interfaces demand colorimetric depth
- Don't apply border-radius between 13px and 99998px -- the system jumps from 12px (large card) directly to pill (99999px)
- Don't mix the coral-red CTA with the electric blue interactive color in the same element
- Don't use heavy font weights (700+) -- the system maxes out at 600 and only for 11px uppercase labels
- Don't place light text on light surfaces or dark text on dark surfaces without checking the gray-on-gray contrast ratio
- Don't use traditional offset box-shadows -- ring shadows (0 0 0 Npx) or border-based containment only
- Don't break the tight line-height on headings -- 1.00-1.24 is the range, never go to 1.5+ for display text
