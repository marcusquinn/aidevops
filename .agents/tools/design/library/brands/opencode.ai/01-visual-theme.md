# Design System: OpenCode — Visual Theme & Atmosphere

OpenCode's website embodies a terminal-native, monospace-first aesthetic that reflects its identity as an open source AI coding agent. The entire visual system is built on a stark dark-on-light contrast using a near-black background (`#201d1d`) with warm off-white text (`#fdfcfc`). This isn't a generic dark theme -- it's a warm, slightly reddish-brown dark that feels like a sophisticated terminal emulator rather than a cold IDE. The warm undertone in both the darks and lights (notice the subtle red channel in `#201d1d` -- rgb(32, 29, 29)) creates a cohesive, lived-in quality.

Berkeley Mono is the sole typeface, establishing an unapologetic monospace identity. Every element -- headings, body text, buttons, navigation -- shares this single font family, creating a unified "everything is code" philosophy. The heading at 38px bold with 1.50 line-height is generous and readable, while body text at 16px with weight 500 provides a slightly heavier-than-normal reading weight that enhances legibility on screen. The monospace grid naturally enforces alignment and rhythm across the layout.

The color system is deliberately minimal. The primary palette consists of just three functional tones: the warm near-black (`#201d1d`), a medium warm gray (`#9a9898`), and a bright off-white (`#fdfcfc`). Semantic colors borrow from the Apple HIG palette -- blue accent (`#007aff`), red danger (`#ff3b30`), green success (`#30d158`), orange warning (`#ff9f0a`) -- giving the interface familiar, trustworthy signal colors without adding brand complexity. Borders use a subtle warm transparency (`rgba(15, 0, 0, 0.12)`) that ties into the warm undertone of the entire system.

**Key Characteristics:**
- Berkeley Mono as the sole typeface -- monospace everywhere, no sans-serif or serif voices
- Warm near-black primary (`#201d1d`) with reddish-brown undertone, not pure black
- Off-white text (`#fdfcfc`) with warm tint, not pure white
- Minimal 4px border radius throughout -- sharp, utilitarian corners
- 8px base spacing system scaling up to 96px
- Apple HIG-inspired semantic colors (blue, red, green, orange)
- Transparent warm borders using `rgba(15, 0, 0, 0.12)`
- Email input with generous 20px padding and 6px radius -- the most generous component radius
- Single button variant: dark background, light text, tight vertical padding (4px 20px)
- Underlined links as default link style, reinforcing the text-centric identity
