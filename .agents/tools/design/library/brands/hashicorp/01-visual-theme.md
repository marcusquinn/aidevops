# Visual Theme & Atmosphere

HashiCorp's website is enterprise infrastructure made tangible — a design system that must communicate the complexity of cloud infrastructure management while remaining approachable. The visual language splits between two modes: a clean white light-mode for informational sections and a dramatic dark-mode (`#15181e`, `#0d0e12`) for hero areas and product showcases, creating a day/night duality that mirrors the "build in light, deploy in dark" developer workflow.

The typography is anchored by a custom brand font (HashiCorp Sans, loaded as `__hashicorpSans_96f0ca`) that carries substantial weight — literally. Headings use 600–700 weights with tight line-heights (1.17–1.19), creating dense, authoritative text blocks that communicate enterprise confidence. The hero headline at 82px weight 600 with OpenType `"kern"` enabled is not decorative — it's infrastructure-grade typography.

What distinguishes HashiCorp is its multi-product color system. Each product in the portfolio has its own brand color — Terraform purple (`#7b42bc`), Vault yellow (`#ffcf25`), Waypoint teal (`#14c6cb`), Vagrant blue (`#1868f2`) — and these colors appear throughout as accent tokens via a CSS custom property system (`--mds-color-*`). This creates a design system within a design system: the parent brand is black-and-white with blue accents, while each child product injects its own chromatic identity.

The component system uses the `mds` (Markdown Design System) prefix, indicating a systematic, token-driven approach where colors, spacing, and states are all managed through CSS variables. Shadows are remarkably subtle — dual-layer micro-shadows using `rgba(97, 104, 117, 0.05)` that are nearly invisible but provide just enough depth to separate interactive surfaces from the background.

## Key Characteristics

- Dual-mode: clean white sections + dramatic dark (`#15181e`) hero/product areas
- Custom HashiCorp Sans font with 600–700 weights and `"kern"` feature
- Multi-product color system via `--mds-color-*` CSS custom properties
- Product brand colors: Terraform purple, Vault yellow, Waypoint teal, Vagrant blue
- Uppercase letter-spaced captions (13px, weight 600, 1.3px letter-spacing)
- Micro-shadows: dual-layer at 0.05 opacity — depth through whisper, not shout
- Token-driven `mds` component system with semantic variable names
- Tight border radius: 2px–8px, nothing pill-shaped or circular
- System-ui fallback stack for secondary text
