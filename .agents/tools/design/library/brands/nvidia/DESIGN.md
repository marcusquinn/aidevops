# Design System: NVIDIA

High-contrast, technology-forward design system. Black/white foundation with NVIDIA Green (`#76b900`) as the sole accent — a signal color, never a surface fill.

## Chapters

| # | File | Contents |
|---|------|----------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| 2 | [02-color-palette.md](02-color-palette.md) | Full color palette, roles, interactive states |
| 3 | [03-typography.md](03-typography.md) | Font family, hierarchy table, principles |
| 4 | [04-components.md](04-components.md) | Buttons, cards, links, navigation, distinctive components |
| 5 | [05-layout.md](05-layout.md) | Spacing system, grid, whitespace, border radius scale |
| 6 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels, shadow philosophy, decorative depth |
| 7 | [07-responsive.md](07-responsive.md) | Breakpoints, collapsing strategy, dark/light section strategy |
| 8 | [08-agent-prompts.md](08-agent-prompts.md) | Quick color reference, example prompts, iteration guide |

## Quick Reference

**Palette essentials:**

- Dark bg: `#000000` (dominant), `#1a1a1a` (card surfaces)
- Light bg: `#ffffff`
- Text dark bg: `#ffffff`, `#a7a7a7` (muted)
- Text light bg: `#000000`, `#1a1a1a`
- Accent: NVIDIA Green `#76b900` — borders, underlines, highlights only
- Link hover: `#3860be` (blue, universal)
- Button hover: `#1eaedb` (teal)

**Typography essentials:**

- Font: `NVIDIA-EMEA`, Arial/Helvetica fallback
- Weight 700 dominant (headings, buttons, links, labels); 400 for body only
- Heading line-height: 1.25 (tight); body: 1.50–1.67 (relaxed)
- Navigation: 14px uppercase weight 700

**Signature patterns:**

- Border radius: 2px everywhere (sharp, industrial)
- Primary button: transparent + `2px solid #76b900`; filled only on hover/active
- Card shadow: `rgba(0, 0, 0, 0.3) 0px 0px 5px 0px`
- Focus ring: `2px solid #000000`
- Dark/light sections alternate — green accent consistent on both
