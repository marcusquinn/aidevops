# 6. Depth & Elevation

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Almost everything — the default |
| 1 | Raised | `0 1px 4px rgba(0, 0, 0, 0.04)` | Newsletter signup card, floating TOC |
| 2 | Elevated | `0 4px 16px rgba(0, 0, 0, 0.06)` | Image lightbox, expanded footnote |
| 3 | Overlay | `0 12px 32px rgba(0, 0, 0, 0.1)` | Modal dialogs, share menu |

**Elevation principles:**

- Shadows are rare in this system — flat is the overwhelming default
- When shadows are used, they are soft and warm (neutral black, low opacity)
- No coloured shadows, no inner shadows
- Borders (`#E8E4DF`) are preferred over shadows for separation
- Modal backdrop: `rgba(0, 0, 0, 0.25)` — very light, keeping the calm atmosphere
