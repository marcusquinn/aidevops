# Design System: Composio — Do's and Don'ts

## Do

- Use Void Black (`#0f0f0f`) as the primary page background — never pure white for main surfaces
- Keep heading line-heights ultra-tight (0.87-1.0) for compressed, authoritative text blocks
- Use white-opacity borders (4-12%) for containment — they're more important than shadows here
- Reserve Electric Cyan (`#00ffff`) for high-signal moments only — CTAs, glows, interactive accents
- Pair abcDiatype with JetBrains Mono to reinforce the developer-tool identity
- Use the hard-offset shadow (`4px 4px`) intentionally on select elements for brutalist personality
- Keep button text dark (`oklch(0.145 0 0)`) even on the darkest backgrounds — buttons carry their own surface
- Layer opacity-based borders to create subtle depth without shadows
- Use uppercase + letter-spacing only for tiny overline labels (12px or smaller)

## Don't

- Don't use bright backgrounds or light surfaces as primary containers
- Don't apply heavy shadows everywhere — depth comes from border opacity, not box-shadow
- Don't use Composio Cobalt (`#0007cd`) as a text color — it's too dark on dark and too saturated on light
- Don't increase heading line-heights beyond 1.2 — the compressed feel is core to the identity
- Don't use bold (700) weight for body or heading text — 400-500 is the ceiling
- Don't mix warm colors — the palette is strictly cool (blue, cyan, white, black)
- Don't use border-radius larger than 4px on content cards — the precision of near-square corners is intentional
- Don't place Electric Cyan at full opacity on large surfaces — it's an accent, used at 12% max for backgrounds
- Don't use decorative serif or handwritten fonts — the entire identity is geometric sans + monospace
- Don't skip the monospace font for technical content — JetBrains Mono is not decorative, it's a credibility signal
