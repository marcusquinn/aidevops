<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Component Stylings

## Buttons

### Primary Dark

- Background: `#15181e` | Text: `#d5d7db`
- Padding: 9px 9px 9px 15px | Radius: 5px
- Border: `1px solid rgba(178, 182, 189, 0.4)`
- Shadow: `rgba(97, 104, 117, 0.05) 0px 1px 1px, rgba(97, 104, 117, 0.05) 0px 2px 2px`
- Focus: `3px solid var(--mds-color-focus-action-external)`
- Hover: `--mds-color-surface-interactive`

### Secondary White

- Background: `#ffffff` | Text: `#3b3d45`
- Padding: 8px 12px | Radius: 4px
- Hover: `--mds-color-surface-interactive` + low-shadow elevation
- Focus: `3px solid transparent`

### Product-Colored Buttons

- Terraform: `#7b42bc` | Vault: `#ffcf25` (dark text) | Waypoint: `#14c6cb`, hover `#12b6bb`

## Badges / Pills

- Background: `#42225b` | Text: `#efeff1`
- Padding: 3px 7px | Radius: 5px | Font: 16px
- Border: `1px solid rgb(180, 87, 255)`

## Inputs

### Text Input (Dark Mode)

- Background: `#0d0e12` | Text: `#efeff1`
- Border: `1px solid rgb(97, 104, 117)` | Padding: 11px | Radius: 5px
- Focus: `3px solid var(--mds-color-focus-action-external)`

### Checkbox

- Background: `#0d0e12` | Border: `1px solid rgb(97, 104, 117)` | Radius: 3px

## Links

| Context | Color | Hover |
|---------|-------|-------|
| Action on Light | `#2264d6` | `var(--wpl-blue-600)`, underline |
| Action on Dark | `#1060ff` / `#2b89ff` | underline |
| White on Dark | `#ffffff` | visible underline |
| Neutral on Light | `#3b3d45` | visible underline |
| Light on Dark | `#efeff1` | visible underline |

## Cards & Containers

- Light: white bg, micro-shadow | Dark: `#15181e` or deeper
- Radius: 8px | Product cards: gradient borders or accent lighting

## Navigation

- Horizontal nav, mega-menu dropdowns | Logo left-aligned
- Links: system-ui 15px weight 500
- CTAs: "Get started" + "Contact us" in header
- Dark mode variant for hero sections
