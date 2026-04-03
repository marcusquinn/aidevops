# Design System: Startup Minimal

## 1. Visual Theme & Atmosphere

Startup Minimal is a clean, focused design system that strips away everything non-essential. It is the design equivalent of a well-written function: no dead code, no unnecessary abstractions, just the work. Inspired by developer tools, productivity software, and platforms that let content speak, this system earns trust through restraint rather than decoration.

The palette is almost monochromatic — near-white backgrounds, charcoal text, and a single blue accent that does all the heavy lifting for interactive states. There are no gradients, no coloured shadows, no decorative elements. Hierarchy comes from typography weight and size, spacing rhythm, and the deliberate placement of the accent colour. When something is blue, it's important. Everything else steps back.

Layout follows a strict 4px base grid with razor-thin borders (1px, light grey) as the primary structural element. Components are tight, spacing is precise, and every pixel is accountable to the grid. The result is a system that feels fast, reliable, and engineered — the kind of interface where users trust that nothing is wasted.

**Key characteristics:**
- **Mood:** Clean, focused, precise, trustworthy, engineered
- **Background:** Near-white `#fafafa` with `#ffffff` card surfaces
- **Signature colour:** Single blue accent `#2563eb` — the only colour that matters
- **Typography feel:** System-first, clean sans-serif, no ornamentation
- **Corner treatment:** Minimal — 6px default, 8px for containers
- **Border style:** Razor-thin 1px `#e5e7eb`, structural, everywhere
- **Shadow approach:** Almost none — borders and background shifts do the work
- **Density:** Medium-high — efficient use of space, never wasteful
- **Motion:** Functional — 150ms ease, state transitions only, no entrance animations

## 2. Colour Palette & Roles

### Primary
| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#2563eb` | CTAs, links, focus rings, active states |
| Primary Hover | `#1d4ed8` | Hover state |
| Primary Dark | `#1e40af` | Active/pressed state |
| Primary Light | `#dbeafe` | Selected backgrounds, badge fills |
| Primary Ghost | `rgba(37, 99, 235, 0.05)` | Subtle hover tints |

### Text
| Role | Hex | Usage |
|------|-----|-------|
| Text Primary | `#18181b` | Headings, primary body content |
| Text Secondary | `#71717a` | Descriptions, captions |
| Text Tertiary | `#a1a1aa` | Placeholders, disabled text |
| Text Inverse | `#ffffff` | Text on primary backgrounds |
| Text Link | `#2563eb` | Inline links (same as primary) |

### Surface
| Role | Hex | Usage |
|------|-----|-------|
| Background | `#fafafa` | Page background |
| Surface | `#ffffff` | Cards, inputs, elevated areas |
| Surface Alt | `#f4f4f5` | Alternating rows, code blocks, secondary surfaces |
| Border Default | `#e5e7eb` | All borders — cards, inputs, dividers |
| Border Subtle | `#f4f4f5` | Inner dividers, nested separators |
| Border Focus | `#2563eb` | Focus rings |
| Border Strong | `#d4d4d8` | Emphasized borders, active inputs |

### Semantic
| Role | Hex | Usage |
|------|-----|-------|
| Success | `#16a34a` | Confirmations, online |
| Success Background | `#f0fdf4` | Success banners |
| Warning | `#ca8a04` | Caution, review |
| Warning Background | `#fefce8` | Warning banners |
| Error | `#dc2626` | Errors, destructive |
| Error Background | `#fef2f2` | Error banners |
| Info | `#2563eb` | Informational (shares primary) |
| Info Background | `#eff6ff` | Info banners |

### Shadows
| Role | Value | Usage |
|------|-------|-------|
| Subtle | `0 1px 2px rgba(0, 0, 0, 0.04)` | Barely-there lift for inputs |
| Medium | `0 2px 8px rgba(0, 0, 0, 0.06)` | Dropdowns, popovers |
| Overlay | `0 4px 16px rgba(0, 0, 0, 0.08)` | Modals, command palette |

## 3. Typography Rules

### Font Families
| Role | Stack |
|------|-------|
| Sans | `'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif` |
| Mono | `'Geist Mono', 'JetBrains Mono', 'SF Mono', 'Consolas', monospace` |

### Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Sans | 48px | 700 | 1.1 | -0.03em | Landing page hero only |
| H1 | Sans | 36px | 600 | 1.15 | -0.025em | Page titles |
| H2 | Sans | 28px | 600 | 1.2 | -0.02em | Section headings |
| H3 | Sans | 22px | 600 | 1.25 | -0.015em | Subsection headings |
| H4 | Sans | 18px | 600 | 1.3 | -0.01em | Card titles, group labels |
| H5 | Sans | 15px | 600 | 1.4 | 0 | Small headings, sidebar titles |
| Body | Sans | 15px | 400 | 1.6 | -0.006em | Primary reading text |
| Body Small | Sans | 13px | 400 | 1.5 | 0 | Captions, help text |
| Label | Sans | 13px | 500 | 1.4 | 0 | Form labels, table headers |
| Tiny | Sans | 11px | 500 | 1.3 | 0.02em | Badges, status indicators |
| Code Block | Mono | 14px | 400 | 1.6 | 0 | Code snippets |
| Code Inline | Mono | 13px | 400 | inherit | 0 | Inline code in body |

### Typography Principles
- One typeface does everything — Inter (or system font fallback) across all roles
- Hierarchy is achieved through size and weight, never through font-family switching
- Headings use 600 weight (semi-bold), not 700/800 — authority without shouting
- Monospace is reserved strictly for code and machine-readable content
- 15px base (not 16px) for a slightly tighter, more tool-like feel
- Maximum content width for body text: 680px (for readability)

## 4. Component Stylings

### Buttons

**Primary Button**
```
background: #2563eb
color: #ffffff
font: 13px/1 Inter, 500
padding: 8px 16px
border: none
border-radius: 6px
transition: background 150ms ease

:hover    → background: #1d4ed8
:active   → background: #1e40af
:focus    → outline: 2px solid #2563eb; outline-offset: 1px
:disabled → background: #93c5fd; cursor: not-allowed
```

**Secondary Button**
```
background: #ffffff
color: #18181b
font: 13px/1 Inter, 500
padding: 8px 16px
border: 1px solid #e5e7eb
border-radius: 6px

:hover    → background: #fafafa; border-color: #d4d4d8
:active   → background: #f4f4f5
:focus    → outline: 2px solid #2563eb; outline-offset: 1px
:disabled → color: #a1a1aa; background: #fafafa
```

**Ghost Button**
```
background: transparent
color: #71717a
font: 13px/1 Inter, 500
padding: 8px 16px
border: none
border-radius: 6px

:hover    → color: #18181b; background: rgba(0, 0, 0, 0.04)
:active   → background: rgba(0, 0, 0, 0.06)
```

**Danger Button**
```
background: #dc2626
color: #ffffff
font: 13px/1 Inter, 500
padding: 8px 16px
border: none
border-radius: 6px

:hover    → background: #b91c1c
:active   → background: #991b1b
```

### Inputs
```
background: #ffffff
color: #18181b
font: 14px Inter
padding: 8px 12px
border: 1px solid #e5e7eb
border-radius: 6px
box-shadow: 0 1px 2px rgba(0, 0, 0, 0.04)
transition: border-color 150ms ease

::placeholder → color: #a1a1aa
:hover        → border-color: #d4d4d8
:focus        → border-color: #2563eb; box-shadow: 0 0 0 3px rgba(37, 99, 235, 0.1); outline: none
:invalid      → border-color: #dc2626
:disabled     → background: #f4f4f5; color: #a1a1aa
```

### Links
```
color: #2563eb
text-decoration: none
transition: color 150ms ease

:hover  → color: #1d4ed8; text-decoration: underline
:active → color: #1e40af
```

### Cards
```
background: #ffffff
border: 1px solid #e5e7eb
border-radius: 8px
padding: 24px

(No shadow at rest. No hover animation by default — add only if the card is interactive/clickable.)

Interactive variant:
:hover → border-color: #d4d4d8; box-shadow: 0 2px 8px rgba(0, 0, 0, 0.06)
```

### Navigation
```
Background: #ffffff
Border bottom: 1px solid #e5e7eb
Height: 56px
Logo: 18px Inter 600 #18181b (text wordmark) or small logomark
Nav items: 14px Inter, 500, #71717a
Active item: #18181b, font-weight: 500
Hover item: #18181b
CTA in nav: small primary button
```

## 5. Layout Principles

### Spacing Scale (4px base unit)
| Token | Value | Usage |
|-------|-------|-------|
| space-0.5 | 2px | Micro adjustments, border offsets |
| space-1 | 4px | Tight inline gaps |
| space-2 | 8px | Input padding, compact gaps |
| space-3 | 12px | Component internal padding |
| space-4 | 16px | Default gaps, card internal spacing |
| space-5 | 20px | Small section gaps |
| space-6 | 24px | Card padding, form groups |
| space-8 | 32px | Section gaps |
| space-10 | 40px | Inter-section spacing |
| space-12 | 48px | Major section breaks |
| space-16 | 64px | Page sections |
| space-20 | 80px | Hero padding |

### Grid
- 12-column grid
- Gutter: 16px (mobile), 20px (tablet), 24px (desktop)
- Max container: 1200px, centered
- Narrow container: 680px for text-heavy content (docs, articles, settings)

### Breakpoints
| Name | Width | Columns | Gutter |
|------|-------|---------|--------|
| Mobile | 0–639px | 4 | 16px |
| Tablet | 640–1023px | 8 | 20px |
| Desktop | 1024–1199px | 12 | 24px |
| Wide | 1200px+ | 12 | 24px |

### Whitespace Philosophy
Space is information. Tight grouping signals relationship; open gaps signal separation. The 4px grid is the only source of truth — no arbitrary spacing values. Every margin and padding snaps to the grid. The goal is an interface that feels engineered, not designed.

### Border Radius Scale
| Token | Value | Usage |
|-------|-------|-------|
| radius-sm | 4px | Small badges, pills, inline tags |
| radius-md | 6px | Buttons, inputs, default |
| radius-lg | 8px | Cards, containers, modals |
| radius-full | 9999px | Avatars, status indicators |

## 6. Depth & Elevation

| Level | Name | Shadow Value | Usage |
|-------|------|-------------|-------|
| 0 | Flat | `none` | Default — most elements live here |
| 1 | Resting | `0 1px 2px rgba(0, 0, 0, 0.04)` | Inputs at rest, subtle grounding |
| 2 | Raised | `0 2px 8px rgba(0, 0, 0, 0.06)` | Dropdowns, interactive card hover |
| 3 | Overlay | `0 4px 16px rgba(0, 0, 0, 0.08)` | Modals, command palette, popovers |
| Focus | Ring | `0 0 0 3px rgba(37, 99, 235, 0.1)` | Focus state ring on inputs and buttons |

**Elevation principles:**
- Most elements are flat (level 0). Borders, not shadows, create structure.
- Shadow is reserved for elements that float above the page (dropdowns, modals, popovers)
- The system uses only 3 shadow levels total — complexity here is a code smell
- Focus rings use box-shadow for a clean, padded focus indicator
- Never combine border and shadow for structure on the same element — choose one

## 7. Do's and Don'ts

### Do's
1. **Do** let borders do the heavy lifting — 1px `#e5e7eb` is the system's workhorse
2. **Do** use one accent colour (`#2563eb`) consistently — diluting it with secondary colours weakens focus
3. **Do** snap every spacing value to the 4px grid — zero exceptions
4. **Do** use `#fafafa` vs `#ffffff` background shifts for section differentiation (not colour washes)
5. **Do** keep component padding tight (8–12px on buttons, 24px on cards) — this isn't a luxury brand
6. **Do** use monospace for code, IDs, and technical values — and nowhere else
7. **Do** test at 1x zoom on a 1080p screen — this is where most users will experience it

### Don'ts
1. **Don't** use gradients, patterns, or decorative backgrounds — ever
2. **Don't** use coloured shadows — shadows are `rgba(0,0,0,...)` only
3. **Don't** introduce a second accent colour — if you need hierarchy, use weight or size
4. **Don't** use border-radius above 8px on standard components (the system doesn't do "playful")
5. **Don't** add hover animations to non-interactive elements — if it doesn't do something, it shouldn't move
6. **Don't** use font weights below 400 or above 700 — the range is 400 (body), 500 (labels/buttons), 600 (headings)
7. **Don't** use text larger than 48px outside of a dedicated hero section

## 8. Responsive Behaviour

### Breakpoint Behaviour
| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 640px) | Single column. Display type drops to 32px. Navigation collapses to icon menu. Cards stack full-width. Inputs go full-width. Table becomes horizontally scrollable. |
| Tablet (640–1023px) | Two-column layouts where applicable. Cards go 2-up. Sidebar becomes top-mounted tabs. |
| Desktop (1024–1199px) | Full layout. Sidebar visible. 3-column grids. All navigation inline. |
| Wide (1200px+) | Content caps at 1200px. Centred with auto margins. |

### Touch Targets
- Minimum: 44px × 44px tap area
- Buttons: 40px minimum height on mobile (padded to 44px tap area)
- Spacing between tappable elements: 8px minimum
- Form inputs: 44px height on mobile

### Mobile-Specific Rules
- Body text stays at 15px — do not reduce
- Card padding reduces from 24px to 16px
- Section padding reduces from 64px to 40px vertical
- Navigation becomes a minimal icon bar or hamburger menu
- Horizontal overflow: hidden on all containers, scroll on tables/code blocks
- Remove hover-only interactions — all information accessible via tap
- Honour `prefers-reduced-motion` — disable all transitions

## 9. Agent Prompt Guide

### Quick Colour Reference
| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#2563eb` | Blue — the only accent |
| `--color-primary-hover` | `#1d4ed8` | Primary hover |
| `--color-primary-light` | `#dbeafe` | Selection, badges |
| `--color-bg` | `#fafafa` | Page background |
| `--color-surface` | `#ffffff` | Cards, inputs |
| `--color-surface-alt` | `#f4f4f5` | Alt rows, code blocks |
| `--color-text` | `#18181b` | Primary text |
| `--color-text-secondary` | `#71717a` | Secondary text |
| `--color-text-tertiary` | `#a1a1aa` | Placeholders |
| `--color-border` | `#e5e7eb` | All borders |
| `--color-border-strong` | `#d4d4d8` | Emphasised borders |
| `--color-success` | `#16a34a` | Success |
| `--color-warning` | `#ca8a04` | Warning |
| `--color-error` | `#dc2626` | Error |
| `--font-sans` | `'Inter', system-ui, sans-serif` | All text |
| `--font-mono` | `'Geist Mono', 'JetBrains Mono', monospace` | Code |
| `--radius-default` | `6px` | Standard radius |
| `--radius-card` | `8px` | Card radius |

### Ready-to-Use Prompts

**Prompt 1 — Dashboard layout:**
> Build a dashboard on #fafafa background. Left sidebar: #ffffff, 240px width, 1px #e5e7eb right border. Sidebar nav items: 14px Inter 500 #71717a, active item #18181b on #f4f4f5 background with 6px radius. Main content area: 24px padding. Stats row: 4 cards in a grid, #ffffff with 1px #e5e7eb border and 8px radius, 24px padding. Stat value: 28px/600 #18181b. Label: 13px/400 #71717a.

**Prompt 2 — Settings form:**
> Create a settings page. Max-width 680px, centred. Section title: 22px Inter 600 #18181b. Description: 15px #71717a. Form groups: 24px gap. Labels: 13px/500 #18181b above inputs. Inputs: #ffffff, 1px #e5e7eb border, 6px radius, 14px Inter, 8px 12px padding. Focus: #2563eb border with 0 0 0 3px rgba(37,99,235,0.1). Submit: #2563eb primary button right-aligned. Dividers: 1px #e5e7eb between sections.

**Prompt 3 — Data table:**
> Build a data table on #ffffff surface with 1px #e5e7eb border and 8px radius. Header row: #f4f4f5 background, 13px Inter 500 #71717a. Body rows: 14px Inter 400 #18181b, 1px #e5e7eb border-bottom. Row hover: #fafafa background. Selected row: #dbeafe background. Actions column: ghost button icons in #71717a, hover #18181b. Pagination: 13px, bottom-right, small secondary buttons.

**Prompt 4 — Empty state:**
> Design an empty state centred in a #ffffff card with 8px radius and 1px #e5e7eb border. Grey illustration placeholder (64px icon in #a1a1aa). Title: 18px/600 #18181b. Description: 15px/400 #71717a, max 400px. Primary CTA: #2563eb button below. 48px vertical padding.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
