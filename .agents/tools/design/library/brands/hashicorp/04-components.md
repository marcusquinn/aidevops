<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Component Stylings

## Buttons

### Primary Dark

- Background: `#15181e`
- Text: `#d5d7db`
- Padding: 9px 9px 9px 15px (asymmetric, more left padding)
- Radius: 5px
- Border: `1px solid rgba(178, 182, 189, 0.4)`
- Shadow: `rgba(97, 104, 117, 0.05) 0px 1px 1px, rgba(97, 104, 117, 0.05) 0px 2px 2px`
- Focus: `3px solid var(--mds-color-focus-action-external)`
- Hover: uses `--mds-color-surface-interactive` token

### Secondary White

- Background: `#ffffff`
- Text: `#3b3d45`
- Padding: 8px 12px
- Radius: 4px
- Hover: `--mds-color-surface-interactive` + low-shadow elevation
- Focus: `3px solid transparent` outline
- Clean, minimal appearance

### Product-Colored Buttons

- Terraform: background `#7b42bc`
- Vault: background `#ffcf25` (dark text)
- Waypoint: background `#14c6cb`, hover `#12b6bb`
- Each product button follows the same structural pattern but uses its brand color

## Badges / Pills

- Background: `#42225b` (deep purple)
- Text: `#efeff1`
- Padding: 3px 7px
- Radius: 5px
- Border: `1px solid rgb(180, 87, 255)`
- Font: 16px

## Inputs

### Text Input (Dark Mode)

- Background: `#0d0e12`
- Text: `#efeff1`
- Border: `1px solid rgb(97, 104, 117)`
- Padding: 11px
- Radius: 5px
- Focus: `3px solid var(--mds-color-focus-action-external)` outline

### Checkbox

- Background: `#0d0e12`
- Border: `1px solid rgb(97, 104, 117)`
- Radius: 3px

## Links

- **Action Blue on Light**: `#2264d6`, hover → blue-600 variable, underline on hover
- **Action Blue on Dark**: `#1060ff` or `#2b89ff`, underline on hover
- **White on Dark**: `#ffffff`, transparent underline → visible underline on hover
- **Neutral on Light**: `#3b3d45`, transparent underline → visible underline on hover
- **Light on Dark**: `#efeff1`, similar hover pattern
- All links use `var(--wpl-blue-600)` as hover color

## Cards & Containers

- Light mode: white background, micro-shadow elevation
- Dark mode: `#15181e` or darker surfaces
- Radius: 8px for cards and containers
- Product showcase cards with gradient borders or accent lighting

## Navigation

- Clean horizontal nav with mega-menu dropdowns
- HashiCorp logo left-aligned
- system-ui 15px weight 500 for links
- Product categories organized by lifecycle management group
- "Get started" and "Contact us" CTAs in header
- Dark mode variant for hero sections
