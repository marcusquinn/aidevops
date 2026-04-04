# Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow | Black background, text blocks |
| Bordered (Level 1) | `1px solid rgba(65,65,65,0.8)` | Standard cards, containers |
| Subtle (Level 2) | `0px 1px 3px rgba(0,0,0,0.1)` | Subtle card lift |
| Elevated (Level 3) | `0px 10px 15px -3px rgba(0,0,0,0.1)` | Feature cards, hover states |
| Pressed/Inset (Level 4) | `0px 4px 25px rgba(0,0,0,0.14) inset` | Active/pressed elements — "sunk into the surface" |
| Neon Highlight (Level 5) | Neon Volt border (`#faff69`) | Featured/selected cards, maximum emphasis |

## Shadow Philosophy

ClickHouse uses shadows on a black canvas, where they're barely visible — they exist more for subtle dimensionality than obvious elevation. The most distinctive depth mechanism is the **inset shadow** (Level 4), which creates a "pressed into the surface" effect unique to ClickHouse. The neon border highlight (Level 5) is the primary attention-getting depth mechanism.
