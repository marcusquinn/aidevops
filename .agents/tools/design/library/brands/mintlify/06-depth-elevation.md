# Mintlify: Depth & Elevation

| Level | Treatment | Use |
|-------|-----------|-----|
| Flat (Level 0) | No shadow, no border | Page background, text blocks |
| Subtle Border (Level 1) | `1px solid rgba(0,0,0,0.05)` | Standard card borders, dividers |
| Medium Border (Level 1b) | `1px solid rgba(0,0,0,0.08)` | Interactive elements, input borders |
| Ambient Shadow (Level 2) | `rgba(0,0,0,0.03) 0px 2px 4px` | Cards with subtle lift |
| Button Shadow (Level 2b) | `rgba(0,0,0,0.06) 0px 1px 2px` | Button micro-depth |
| Focus Ring (Accessibility) | `1px solid #18E299` outline | Focused inputs, active interactive elements |

**Shadow Philosophy**: Mintlify barely uses shadows. The depth system is almost entirely border-driven — ultra-subtle 5% opacity borders create separation without visual weight. When shadows appear, they're atmospheric whispers (`0.03 opacity, 2px blur, 4px spread`) that add the barest sense of lift. This restraint keeps the page feeling flat and paper-like — appropriate for a documentation company whose product is about clarity and readability.

## Decorative Depth

- Hero gradient: atmospheric green-white cloud gradient behind hero content
- No background color alternation — white on white throughout
- Depth comes from border opacity variation (5% → 8%) and whitespace
