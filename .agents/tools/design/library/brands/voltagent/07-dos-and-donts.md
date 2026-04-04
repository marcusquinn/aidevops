# VoltAgent Design System: Do's and Don'ts

## Do

- Use Abyss Black (`#050507`) as the landing page background and Carbon Surface (`#101010`) for all contained elements — the two-shade dark system is essential
- Reserve Emerald Signal Green (`#00d992`) exclusively for high-signal moments: active borders, glow effects, and the most important interactive accents
- Use VoltAgent Mint (`#2fd6a1`) for button text on dark surfaces — it's more readable than pure Signal Green
- Keep heading line-heights compressed (1.0–1.11) with negative letter-spacing for dense, authoritative text blocks
- Use the warm gray palette (`#3d3a39`, `#8b949e`, `#b8b3b0`) for borders and secondary text — warmth prevents the dark theme from feeling sterile
- Present code snippets as primary content — they're hero elements, not supporting illustrations
- Use border weight (1px → 2px → 3px) and color shifts (`#3d3a39` → `#00d992`) to communicate depth and importance, rather than relying on shadows
- Pair system-ui for headings with Inter for body text — the speed/authority of native fonts combined with the precision of a geometric sans
- Use SFMono-Regular for all code content — it's the developer credibility signal
- Apply `"calt"` and `"rlig"` OpenType features across all text

## Don't

- Don't use bright or light backgrounds as primary surfaces — the entire identity lives on near-black
- Don't introduce warm colors (orange, red, yellow) as decorative accents — the palette is strictly green + warm neutrals on black. Warm colors are reserved for semantic states (warning, error) only
- Don't use Emerald Signal Green (`#00d992`) on large surfaces or as background fills — it's an accent, never a surface
- Don't increase heading line-heights beyond 1.33 — the compressed density is core to the engineering-platform identity
- Don't use heavy shadows generously — depth comes from border treatment, not box-shadow. Shadows are reserved for Level 4–5 elevation only
- Don't use pure white (`#ffffff`) as default body text — Snow White (`#f2f2f2`) is the standard. Pure white is reserved for maximum-emphasis headings and button text
- Don't mix in serif or decorative fonts — the entire system is geometric sans + monospace
- Don't use border-radius larger than 8px on content cards — 9999px (pill) is only for small tags and badges
- Don't skip the warm-gray border system — cards without `#3d3a39` borders lose their containment and float ambiguously on the dark canvas
- Don't animate aggressively — animations are slow and subtle (25–100s durations for marquee, gentle glow pulses). Fast motion contradicts the "engineering precision" atmosphere
