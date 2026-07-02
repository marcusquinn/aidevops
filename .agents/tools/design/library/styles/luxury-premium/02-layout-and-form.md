<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Luxury Premium Layout and Form

## 4. Layout

### Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline micro-spacing |
| `--space-2` | 8px | Icon gaps, tight pairs |
| `--space-3` | 16px | Component internal spacing |
| `--space-4` | 24px | Card content padding |
| `--space-5` | 32px | Card padding, navigation gaps |
| `--space-6` | 48px | Section internal padding |
| `--space-7` | 80px | Section separation |
| `--space-8` | 120px | Major section breaks |
| `--space-9` | 160px | Hero padding, dramatic spacing |
| `--space-10` | 240px | Full viewport breathing room |

### Grid

- 12-column grid, 32px gutter
- Asymmetric layouts encouraged (e.g., 5/7, 4/8, 3/9 splits)
- Full-bleed images are a primary layout tool
- Content often occupies only 50-60% of the viewport width

### Container Widths

| Breakpoint | Container | Behaviour |
|-----------|-----------|-----------|
| >=1440px | 1400px | Centred, generous side margins |
| 1024-1439px | 100% | 64px side padding |
| 768-1023px | 100% | 48px side padding |
| <768px | 100% | 24px side padding |

### Whitespace Philosophy

Negative space is the primary design material. Sections: 80-160px blackspace separation. Content in narrow columns; content-to-space ratio 30:70 or 20:80. Spatial generosity distinguishes luxury from merely dark themes.

## 5. Elevation & Depth

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Default — most elements |
| 1 | Subtle | `0 2px 8px rgba(0, 0, 0, 0.3)` | Floating navigation (scrolled) |
| 2 | Elevated | `0 8px 32px rgba(0, 0, 0, 0.4)` | Image lightbox, overlays |
| 3 | Cinematic | `0 24px 64px rgba(0, 0, 0, 0.6)` | Modal dialogs |

**Elevation principles:**
- Shadows are nearly invisible on dark backgrounds — use border-light or background contrast instead
- Depth is primarily communicated through `backdrop-filter: blur()` and layered opacity
- Glass effect: `background: rgba(0, 0, 0, 0.7); backdrop-filter: blur(16px)`
- Modal backdrop: `rgba(0, 0, 0, 0.7)` — very dark, cinematic
- Avoid box-shadow as a primary depth cue — it reads as cheap on dark interfaces

## 6. Shapes

The shape language is defined by **Architectural Sharpness**. Sharp edges throughout — rounded corners are antithetical to the luxury aesthetic.

### Rounded Scale

| Token | Value | Usage |
|-------|-------|-------|
| `none` | 0px | Buttons, inputs, cards — the default |
| `sm` | 2px | Rare — small interactive elements only |
| `full` | 9999px | Avatars only (if used at all) |
