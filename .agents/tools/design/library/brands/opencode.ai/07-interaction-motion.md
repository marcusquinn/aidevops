# Design System: OpenCode — Interaction & Motion

## Hover States

- Links: color shift from default to accent blue (`#007aff`) or underline style change
- Buttons: subtle background lightening or border emphasis
- Accent blue provides a three-stage hover sequence: `#007aff` → `#0056b3` → `#004085` (default → hover → active)
- Danger red: `#ff3b30` → `#d70015` → `#a50011`
- Warning orange: `#ff9f0a` → `#cc7f08` → `#995f06`

## Focus States

- Border-based focus: increased border opacity or solid border color
- No shadow-based focus rings -- consistent with the flat, no-shadow aesthetic
- Keyboard focus likely uses outline or border color shift to accent blue

## Transitions

- Minimal transitions expected -- terminal-inspired interfaces favor instant state changes
- Color transitions: 100-150ms for subtle state feedback
- No scale, rotate, or complex transform animations
