# Depth & Elevation

## Elevation Levels

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow | Page backgrounds, inline text |
| Subtle (Level 1) | `rgba(0,0,0,0.3) 0px 0px 5px 0px` | Standard cards, modals |
| Border (Level 1b) | `1px solid #5e5e5e` | Content dividers, section borders |
| Green accent (Level 2) | `2px solid #76b900` | Active elements, CTAs, selected items |
| Focus (Accessibility) | `2px solid #000000` outline | Keyboard focus ring |

## Shadow Philosophy

NVIDIA's depth system is minimal and utilitarian. There is essentially one shadow value — a 5px ambient blur at 30% opacity — used sparingly for cards and modals. The primary depth signal is not shadow but _color contrast_: black backgrounds next to white sections, green borders on black surfaces. This creates hardware-like visual layering where depth comes from material difference, not simulated light.

## Decorative Depth

- Green gradient washes behind hero content
- Dark-to-darker gradients (black to near-black) for section transitions
- No glassmorphism or blur effects — clarity over atmosphere
