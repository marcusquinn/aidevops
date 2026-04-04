# Design System: Developer Dark — Visual Theme & Atmosphere

A terminal-native dark interface built for developers who live in their editor. The design takes its cues from modern IDE themes and terminal emulators -- deep grey backgrounds (`#111827`) that are easier on the eyes than pure black, with a carefully chosen palette of terminal-green (`#4ade80`), amber warnings (`#fbbf24`), and error red (`#ef4444`) that map directly to the semantic colours developers already associate with success, caution, and failure.

Typography is monospace-first. JetBrains Mono serves as the primary font for all headings and code, reinforcing the terminal aesthetic, while Inter handles body text where readability at smaller sizes matters more than character alignment. The system is information-dense by design -- small base spacing (4px), compact padding, and minimal border-radius (4px) create a utilitarian interface where screen real-estate is maximised for content. Every pixel serves a purpose.

The depth model is deliberately flat. Shadows are minimal and cool-toned, borders do the heavy lifting for structural separation. Interactive elements use colour changes rather than elevation shifts -- a philosophy borrowed from terminal interfaces where the cursor is the primary focus indicator. The overall impression is of a system designed by engineers, for engineers: precise, dense, and efficient.

## Key Characteristics

- Deep grey background (`#111827`) -- never pure black, prevents OLED flicker
- Terminal-green accent (`#4ade80`) for success states and primary interactive elements
- Amber (`#fbbf24`) for warnings and secondary highlights
- JetBrains Mono as primary display/heading font with ligatures enabled
- Inter as body font for readability at 14-16px
- 4px base spacing unit for dense, compact layouts
- Minimal border-radius (4px) -- sharp but not brutal
- Border-driven structure (`#1f2937`) rather than shadow-driven depth
- Semantic colour mapping: green=success, amber=warning, red=error, blue=info
- Focus rings use visible outline (`2px solid #4ade80`) -- no subtle indicators
