# Agency Feminine — Depth & Elevation

| Level | Name | Shadow Value | Usage |
|-------|------|-------------|-------|
| 0 | Flat | `none` | Default state, sections on cream bg |
| 1 | Resting | `0 2px 12px rgba(61, 53, 48, 0.06)` | Cards at rest, subtle lift |
| 2 | Raised | `0 4px 24px rgba(61, 53, 48, 0.08)` | Hover cards, dropdowns |
| 3 | Elevated | `0 8px 40px rgba(61, 53, 48, 0.1)` | Modals, overlays, popovers |
| 4 | Overlay | `0 16px 56px rgba(61, 53, 48, 0.12)` | Full-screen overlays, lightboxes |
| Glow | Warm | `0 0 20px rgba(212, 165, 165, 0.15)` | CTA emphasis, focus state glow |

**Elevation principles:**

- Shadows are warm-toned (based on `#3d3530` not pure black) to match the cream palette
- Depth is gentle and diffuse — no sharp, dark drop shadows
- Use background colour shifts (`#f8f0e5` → `#ffffff`) as the primary layering mechanism
- Shadow only supplements colour layering, it doesn't replace it
- The warm glow shadow on primary elements creates a soft halo effect, not a hard edge
