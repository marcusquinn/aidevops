<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Nothing Design System — Color System

## Primary Palette (Dark Mode)

| Token | Hex | Contrast on #000 | Role |
|-------|-----|-------------------|------|
| `--black` | `#000000` | -- | Primary background (OLED) |
| `--surface` | `#111111` | 1.3:1 | Elevated surfaces, cards |
| `--surface-raised` | `#1A1A1A` | 1.5:1 | Secondary elevation |
| `--border` | `#222222` | -- | Subtle dividers (decorative only) |
| `--border-visible` | `#333333` | -- | Intentional borders, wireframe lines |
| `--text-disabled` | `#666666` | 4.0:1 | Disabled text, decorative elements |
| `--text-secondary` | `#999999` | 6.3:1 | Labels, captions, metadata |
| `--text-primary` | `#E8E8E8` | 16.5:1 | Body text |
| `--text-display` | `#FFFFFF` | 21:1 | Headlines, hero numbers |

## Accent & Status Colors

| Token | Hex | Usage |
|-------|-----|-------|
| `--accent` | `#D71921` | Signal light: active states, destructive, urgent. One per screen as UI element. Never decorative. |
| `--accent-subtle` | `rgba(215,25,33,0.15)` | Accent tint backgrounds |
| `--success` | `#4A9E5C` | Confirmed, completed, connected |
| `--warning` | `#D4A843` | Caution, pending, degraded |
| `--error` | `#D71921` | Shares accent red -- errors ARE the accent moment |
| `--info` | `#999999` | Uses secondary text color |
| `--interactive` | `#007AFF` / `#5B9BF6` | Tappable text: links, picker values. Not for buttons. |

Data status: `--success` = good, `--warning` = attention, `--accent` = bad/over limit, `--text-primary` = neutral. Apply color to **value**, not label or background. Labels stay `--text-secondary`. Trend arrows inherit value color.

## Dark / Light Mode

| Token | Dark | Light |
|-------|------|-------|
| `--black` | `#000000` | `#F5F5F5` |
| `--surface` | `#111111` | `#FFFFFF` |
| `--surface-raised` | `#1A1A1A` | `#F0F0F0` |
| `--border` | `#222222` | `#E8E8E8` |
| `--border-visible` | `#333333` | `#CCCCCC` |
| `--text-disabled` | `#666666` | `#999999` |
| `--text-secondary` | `#999999` | `#666666` |
| `--text-primary` | `#E8E8E8` | `#1A1A1A` |
| `--text-display` | `#FFFFFF` | `#000000` |
| `--interactive` | `#5B9BF6` | `#007AFF` |

Identical across modes: accent red, status colors, ALL CAPS labels, fonts, type scale, spacing, component shapes.

Dark: OLED black, white data glowing (instrument panel). Light: off-white paper (#F5F5F5), black ink; cards `#FFFFFF` = subtle elevation without shadows.
