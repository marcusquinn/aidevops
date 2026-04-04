# Design System: Resend — Depth & Elevation

## Elevation Levels

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow, transparent background | Default — most elements on dark void |
| Ring (Level 1) | `rgba(176, 199, 217, 0.145) 0px 0px 0px 1px` | Shadow-as-border for cards, containers |
| Frost Border (Level 1b) | `1px solid rgba(214, 235, 253, 0.19)` | Explicit borders — buttons, dividers, tabs |
| Subtle (Level 2) | `rgba(0, 0, 0, 0.1) 0px 1px 3px, rgba(0, 0, 0, 0.1) 0px 1px 2px -1px` | Light card elevation |
| Focus (Level 3) | `rgb(0, 0, 0) 0px 0px 0px 8px` | Heavy black focus ring — accessibility |

## Shadow Philosophy

Resend barely uses shadows at all. On a pure black background, traditional shadows are invisible — you can't cast a shadow into the void. Instead, Resend creates depth through its signature frost borders (`rgba(214, 235, 253, 0.19)`) — thin, icy blue-tinted lines that catch light against the darkness. This creates a "glass panel floating in space" aesthetic where borders are the primary depth mechanism.

## Decorative Depth

- Subtle warm gradient glows behind hero content (orange/amber tints)
- Product screenshots create visual depth through their own internal UI
- No gradient backgrounds — depth comes from border luminance and content contrast
