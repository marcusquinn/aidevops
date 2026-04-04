# Design System: MongoDB — Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow | Default surfaces |
| Subtle (Level 1) | `rgba(0,0,0,0.1) 0px 2px 4px` | Light card lift |
| Standard (Level 2) | `rgba(0,0,0,0.15) 0px 3px 9px` | Standard cards |
| Prominent (Level 3) | `rgba(0,0,0,0.15) 0px 3px 20px` | Elevated panels |
| Forest (Level 4) | `rgba(0,30,43,0.12) 0px 26px 44px, rgba(0,0,0,0.13) 0px 7px 13px` | Hero cards — teal-tinted |

**Shadow Philosophy**: MongoDB's shadow system is unique in that the primary elevation shadow uses `rgba(0, 30, 43, 0.12)` — a teal-tinted shadow that carries the forest-dark brand color into the depth system. This means even on white surfaces, shadows feel like they belong to the MongoDB color world rather than being generic neutral black.
