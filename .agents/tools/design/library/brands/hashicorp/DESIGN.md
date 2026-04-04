<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: HashiCorp

Enterprise infrastructure design system. Dual light/dark mode with multi-product color system — each product (Terraform, Vault, Waypoint, Vagrant) owns exactly one brand color.

## Chapters

| # | File | Contents |
|---|------|----------|
| 1 | [01-visual-theme.md](01-visual-theme.md) | Visual theme, atmosphere, key characteristics |
| 2 | [02-color-palette.md](02-color-palette.md) | Full color palette, roles, product brand colors |
| 3 | [03-typography.md](03-typography.md) | Font families, hierarchy table, principles |
| 4 | [04-components.md](04-components.md) | Buttons, badges, inputs, links, cards, navigation |
| 5 | [05-layout.md](05-layout.md) | Spacing system, grid, whitespace, border radius scale |
| 6 | [06-depth-elevation.md](06-depth-elevation.md) | Elevation levels, shadow philosophy |
| 7 | [07-dos-donts.md](07-dos-donts.md) | Do's and Don'ts reference |
| 8 | [08-responsive.md](08-responsive.md) | Breakpoints, collapsing strategy |
| 9 | [09-agent-prompts.md](09-agent-prompts.md) | Quick color reference, example prompts, iteration guide |

## Quick Reference

**Palette essentials:**

- Light bg: `#ffffff`, `#f1f2f3`
- Dark bg: `#15181e` (hero/product), `#0d0e12` (deepest)
- Text light: `#000000`, `#3b3d45`
- Text dark: `#efeff1`, `#d5d7db`
- Links: `#2264d6` (light), `#1060ff` (dark)
- Product colors: Terraform `#7b42bc`, Vault `#ffcf25`, Waypoint `#14c6cb`, Vagrant `#1868f2`

**Typography essentials:**

- Headings: HashiCorp Sans (`__hashicorpSans_96f0ca`), 600–700 weight, `"kern"` always on
- Body/UI: system-ui, 400–500 weight, 1.50–1.69 line-height
- Uppercase labels: 13px, weight 600, 1.3px letter-spacing

**Signature patterns:**

- Micro-shadow: `rgba(97, 104, 117, 0.05) 0px 1px 1px, rgba(97, 104, 117, 0.05) 0px 2px 2px`
- Focus ring: `3px solid var(--mds-color-focus-action-external)`
- Token system: `--mds-color-*` CSS custom properties
- Asymmetric primary button padding: 9px 9px 9px 15px
