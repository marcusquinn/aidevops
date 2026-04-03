# Design System: Corporate Traditional — Layout Principles

## Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline spacing, icon gaps |
| `--space-2` | 8px | Tight component padding |
| `--space-3` | 12px | Input padding, compact cards |
| `--space-4` | 16px | Standard component padding |
| `--space-5` | 24px | Card padding, section gaps |
| `--space-6` | 32px | Section padding |
| `--space-7` | 48px | Large section breaks |
| `--space-8` | 64px | Page section separators |
| `--space-9` | 96px | Hero/banner vertical padding |

## Grid

- 12-column grid
- Column gap: 24px (desktop), 16px (tablet)
- Max container width: 1200px
- Content area: centred with `margin: 0 auto`
- Sidebar layout: 3 columns sidebar / 9 columns content (desktop)

## Container Widths

| Breakpoint | Container | Side Padding |
|-----------|-----------|-------------|
| ≥1280px | 1200px (fixed) | auto |
| 1024–1279px | 100% | 48px |
| 768–1023px | 100% | 32px |
| <768px | 100% | 20px |

## Whitespace Philosophy

Space is used to convey structure and hierarchy. Sections are clearly delineated with generous vertical margins (48–96px). Content blocks within sections use 24–32px spacing. Tight spacing (4–8px) is reserved for inline elements and related content groups.

## Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 2px | Tags, badges |
| `--radius-md` | 4px | Buttons, inputs, cards |
| `--radius-lg` | 6px | Modals, dropdowns |
| `--radius-full` | 9999px | Avatars only |
