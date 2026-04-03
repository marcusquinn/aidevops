# Design System: Agency Creative — Responsive Behaviour

## Breakpoint Behaviour

| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 768px) | Single column. Display type scales to 40–48px. Hero padding reduces to 80px vertical. Card grid stacks. Navigation becomes full-screen overlay. Gradient sections become full-width bands. |
| Tablet (768–1023px) | Two-column layouts where appropriate. Display type at 48–56px. Asymmetric layouts become centred. |
| Desktop (1024–1439px) | Full layout with asymmetric grids. All navigation visible. Scroll animations active. |
| Wide (1440px+) | Content caps at 1440px. Full-bleed sections continue edge-to-edge. |

## Touch Targets

- Minimum: 48px × 48px (larger than standard — matches the bold aesthetic)
- CTA buttons: 52px minimum height on mobile
- Card tap targets: entire card surface is tappable

## Mobile-Specific Rules

- Reduce Display XL (80px) to 40px on mobile, maintaining visual weight via bold weight
- Scroll-triggered animations simplify to basic fade-in (preserve battery, reduce motion)
- Gradient backgrounds may simplify to solid primary colour for performance
- Full-screen mobile navigation with large type (32px links) and gradient accent
- Honour `prefers-reduced-motion` — disable all transforms, keep opacity fades only
