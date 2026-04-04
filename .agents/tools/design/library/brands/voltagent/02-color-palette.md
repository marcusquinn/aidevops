<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# VoltAgent Design System: Color Palette & Roles

## Primary

| Name | Hex | Role |
|------|-----|------|
| Emerald Signal Green | `#00d992` | Core brand accent — borders, glow effects, highest-signal interactive moments ("power-on" indicator) |
| VoltAgent Mint | `#2fd6a1` | CTA button text on dark surfaces — warmer and more readable than Signal Green |
| Tailwind Emerald | `#10b981` | Ecosystem-standard green at 30% opacity for background tints and link defaults |

## Secondary & Accent

| Name | Hex | Role |
|------|-----|------|
| Soft Purple | `#818cf8` | Secondary categorization, code syntax highlights — does not compete with green |
| Cobalt Primary | `#306cce` | Docusaurus primary dark — documentation links and interactive focus states |
| Deep Cobalt | `#2554a0` | Darkest primary shade — pressed/active states in documentation UI |
| Ring Blue | `#3b82f6` | Tailwind ring at 50% opacity — keyboard focus indicator for accessibility |

## Surface & Background

| Name | Hex | Role |
|------|-----|------|
| Abyss Black | `#050507` | Landing page canvas — near-pure black with faint warm undertone |
| Carbon Surface | `#101010` | Primary card and button background — one shade above Abyss for elevation |
| Warm Charcoal Border | `#3d3a39` | Containment borders — warm brownish dark tone, not harsh cold gray |

## Neutrals & Text

| Name | Hex | Role |
|------|-----|------|
| Snow White | `#f2f2f2` | Primary text on dark surfaces — softened off-white (1008 instances) |
| Pure White | `#ffffff` | Highest-emphasis moments — ghost button text; 5% opacity for overlays |
| Warm Parchment | `#b8b3b0` | Secondary body text — warm light gray with slight pinkish undertone |
| Steel Slate | `#8b949e` | Tertiary text, metadata, timestamps — cool blue-gray below Warm Parchment |
| Fog Gray | `#bdbdbd` | Footer links and supporting navigation — brightens to Pure White on hover |
| Mist Gray | `#dcdcdc` | Secondary link text — transitions to bright green on hover |
| Near White | `#eeeeee` | Highest-contrast secondary text, one step below Snow White |

## Semantic & Accent

| Name | Hex | Role |
|------|-----|------|
| Success Emerald | `#008b00` | Success states and positive confirmations in documentation |
| Success Light | `#80d280` | Success backgrounds and subtle positive indicators |
| Warning Amber | `#ffba00` | Warning alerts and caution states |
| Warning Pale | `#ffdd80` | Warning background fills |
| Danger Coral | `#fb565b` | Error states and destructive action warnings |
| Danger Rose | `#fd9c9f` | Error backgrounds |
| Info Teal | `#4cb3d4` | Informational callouts and tip admonitions |
| Dashed Border Slate | `#4f5d75` at 40% | Decorative dashed borders in workflow diagrams only |

## Gradient System

- **Green Signal Glow**: `drop-shadow(0 0 2px #00d992)` animating to `drop-shadow(0 0 8px #00d992)` — creates a pulsing "electric charge" effect on the VoltAgent bolt logo and interactive elements. The glow expands and contracts like a heartbeat.
- **Warm Ambient Haze**: `rgba(92, 88, 85, 0.2) 0px 0px 15px` — a warm-toned diffused shadow that creates a soft atmospheric glow around elevated cards, visible at the edges without sharp boundaries.
- **Deep Dramatic Elevation**: `rgba(0, 0, 0, 0.7) 0px 20px 60px` with `rgba(148, 163, 184, 0.1) 0px 0px 0px 1px inset` — a heavy, dramatic downward shadow paired with a faint inset slate ring for the most prominent floating elements.
