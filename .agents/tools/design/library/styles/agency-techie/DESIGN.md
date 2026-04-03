# Design System: Agency Techie

## 1. Visual Theme & Atmosphere

Agency Techie is a dark-mode-first design system built for teams that ship code. It draws its visual language from terminal interfaces, IDE colour schemes, and the dense information architectures of developer tooling. Every element is designed to feel precise, functional, and fast — the digital equivalent of a well-configured workspace.

The palette anchors on near-black surfaces with bright cyan as the primary signal colour, creating a high-contrast environment that reduces eye strain during long sessions while keeping interactive elements unmistakable. Typography leans on monospace accents for data, labels, and code-adjacent content, paired with a clean geometric sans-serif for prose. The overall effect is technical authority without coldness.

Layouts are tight and information-dense. Whitespace is intentional but never wasteful — every pixel earns its place. Corners are sharp (4–6px radius), borders are thin and structural, and shadows are subtle glows rather than diffuse lifts. Motion is minimal and purposeful: state transitions, not spectacle.

**Key characteristics:**
- **Mood:** Precise, technical, authoritative, focused
- **Background:** Near-black `#0d1117` with layered dark surfaces
- **Signature colour:** Bright cyan `#22d3ee` — used sparingly for maximum signal
- **Typography feel:** Monospace-accented, tight, information-dense
- **Corner treatment:** Sharp — 4px default, 6px max for containers
- **Border style:** Thin (1px), structural, `#1e293b` default
- **Shadow approach:** Subtle cyan-tinted glows on interactive elements
- **Density:** High — compact spacing, small base font sizes
- **Motion:** Minimal — 150ms ease-out transitions on state changes only

## 2. Colour Palette & Roles

### Primary
| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#22d3ee` | CTAs, active states, focus rings, key links |
| Primary Hover | `#06b6d4` | Darkened primary for hover states |
| Primary Muted | `#164e63` | Backgrounds behind primary elements, badges |
| Primary Ghost | `rgba(34, 211, 238, 0.08)` | Subtle tints on hover for ghost buttons |

### Accent
| Role | Hex | Usage |
|------|-----|-------|
| Accent | `#a78bfa` | Secondary actions, tags, decorative highlights |
| Accent Hover | `#8b5cf6` | Hover state for accent elements |
| Accent Muted | `#2e1065` | Backgrounds behind accent elements |

### Text
| Role | Hex | Usage |
|------|-----|-------|
| Text Primary | `#e2e8f0` | Headings, body text, primary content |
| Text Secondary | `#94a3b8` | Descriptions, captions, secondary labels |
| Text Tertiary | `#475569` | Placeholders, disabled text, timestamps |
| Text Inverse | `#0d1117` | Text on primary-coloured backgrounds |
| Text Code | `#22d3ee` | Inline code, terminal output, variable names |

### Surface
| Role | Hex | Usage |
|------|-----|-------|
| Background | `#0d1117` | Page background, base layer |
| Surface 1 | `#161b22` | Cards, sidebars, panels |
| Surface 2 | `#1c2333` | Elevated cards, dropdowns, modals |
| Surface 3 | `#243044` | Active states, selected rows, hover backgrounds |
| Border Default | `#1e293b` | Card borders, dividers, input borders |
| Border Subtle | `#162032` | Subtle separators, nested section dividers |
| Border Focus | `#22d3ee` | Focus rings, active input borders |

### Semantic
| Role | Hex | Usage |
|------|-----|-------|
| Success | `#4ade80` | Confirmations, passing tests, online status |
| Success Background | `rgba(74, 222, 128, 0.1)` | Success banners, notification backgrounds |
| Warning | `#fbbf24` | Caution alerts, pending states |
| Warning Background | `rgba(251, 191, 36, 0.1)` | Warning banners |
| Error | `#f87171` | Errors, failed tests, destructive actions |
| Error Background | `rgba(248, 113, 113, 0.1)` | Error banners |
| Info | `#60a5fa` | Informational messages, help text |
| Info Background | `rgba(96, 165, 250, 0.1)` | Info banners |

### Shadows
| Role | Value | Usage |
|------|-------|-------|
| Glow Primary | `0 0 12px rgba(34, 211, 238, 0.15)` | Focused inputs, active buttons |
| Glow Accent | `0 0 12px rgba(167, 139, 250, 0.12)` | Accent element emphasis |
| Shadow Subtle | `0 1px 3px rgba(0, 0, 0, 0.4)` | Slight card lift |

## 3. Typography Rules

### Font Families
| Role | Stack |
|------|-------|
| Mono | `'JetBrains Mono', 'Fira Code', 'Cascadia Code', 'SF Mono', 'Consolas', monospace` |
| Sans | `'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif` |

### Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Sans | 48px | 700 | 1.1 | -0.03em | Landing pages, hero sections |
| H1 | Sans | 36px | 700 | 1.2 | -0.025em | Page titles |
| H2 | Sans | 28px | 600 | 1.25 | -0.02em | Section headings |
| H3 | Sans | 22px | 600 | 1.3 | -0.015em | Subsection headings |
| H4 | Sans | 18px | 600 | 1.35 | -0.01em | Card titles, group labels |
| Body | Sans | 15px | 400 | 1.6 | -0.006em | Primary reading text |
| Body Small | Sans | 13px | 400 | 1.5 | 0 | Secondary descriptions, captions |
| Label | Sans | 12px | 500 | 1.4 | 0.04em | Form labels, column headers (uppercase optional) |
| Code Block | Mono | 14px | 400 | 1.65 | 0 | Code snippets, terminal output |
| Code Inline | Mono | 13px | 400 | inherit | 0 | Inline code within body text |
| Data | Mono | 14px | 500 | 1.4 | 0 | Metrics, stats, API values, IDs |

### Typography Principles
- Use monospace for anything that represents code, data, identifiers, or machine-readable values
- Sans-serif for all human-readable prose, navigation, and UI labels
- Never go below 12px — even for tertiary information
- Heading weight should always be 600+ to maintain hierarchy against dense layouts
- Line-height for body text stays at 1.6 for readability in dark mode (looser than light-mode norms)

## 4. Component Stylings

### Buttons

**Primary Button**
```
background: #22d3ee
color: #0d1117
font: 14px/1 Inter, 500
padding: 10px 20px
border: none
border-radius: 4px
transition: all 150ms ease-out

:hover    → background: #06b6d4; box-shadow: 0 0 12px rgba(34, 211, 238, 0.2)
:active   → background: #0891b2; transform: translateY(1px)
:focus    → outline: 2px solid #22d3ee; outline-offset: 2px
:disabled → background: #164e63; color: #475569; cursor: not-allowed
```

**Secondary Button**
```
background: transparent
color: #e2e8f0
font: 14px/1 Inter, 500
padding: 10px 20px
border: 1px solid #1e293b
border-radius: 4px

:hover    → border-color: #334155; background: rgba(255,255,255,0.03)
:active   → background: rgba(255,255,255,0.06)
:focus    → outline: 2px solid #22d3ee; outline-offset: 2px
:disabled → color: #475569; border-color: #162032; cursor: not-allowed
```

**Ghost Button**
```
background: transparent
color: #94a3b8
font: 14px/1 Inter, 500
padding: 10px 20px
border: none
border-radius: 4px

:hover    → color: #e2e8f0; background: rgba(34, 211, 238, 0.08)
:active   → background: rgba(34, 211, 238, 0.12)
:focus    → outline: 2px solid #22d3ee; outline-offset: 2px
```

### Inputs

```
background: #161b22
color: #e2e8f0
font: 14px JetBrains Mono (for code inputs) or Inter (for text inputs)
padding: 10px 14px
border: 1px solid #1e293b
border-radius: 4px

::placeholder → color: #475569
:hover        → border-color: #334155
:focus        → border-color: #22d3ee; box-shadow: 0 0 0 3px rgba(34, 211, 238, 0.1)
:invalid      → border-color: #f87171
:disabled     → background: #0d1117; color: #475569
```

### Links
```
color: #22d3ee
text-decoration: none
transition: color 150ms ease-out

:hover  → color: #67e8f9; text-decoration: underline
:active → color: #06b6d4
```

### Cards
```
background: #161b22
border: 1px solid #1e293b
border-radius: 6px
padding: 20px
transition: border-color 150ms ease-out

:hover → border-color: #334155
```

### Navigation
```
Background: #0d1117
Border bottom: 1px solid #1e293b
Height: 56px
Logo: left-aligned, 24px mono wordmark
Nav items: 14px Inter, 500, #94a3b8
Active item: #e2e8f0, border-bottom: 2px solid #22d3ee
```

## 5. Layout Principles

### Spacing Scale (4px base unit)
| Token | Value | Usage |
|-------|-------|-------|
| space-1 | 4px | Tight gaps, inline icon padding |
| space-2 | 8px | Input padding, compact list gaps |
| space-3 | 12px | Small component padding, label margins |
| space-4 | 16px | Default component padding, card gaps |
| space-5 | 20px | Section gaps within cards |
| space-6 | 24px | Card padding, form group spacing |
| space-8 | 32px | Section spacing |
| space-10 | 40px | Large section spacing |
| space-12 | 48px | Page section dividers |
| space-16 | 64px | Major page sections |

### Grid
- 12-column grid
- Gutter: 16px (mobile), 24px (tablet), 32px (desktop)
- Max container: 1280px, centered

### Breakpoints
| Name | Width | Columns | Gutter |
|------|-------|---------|--------|
| Mobile | 0–639px | 4 | 16px |
| Tablet | 640–1023px | 8 | 24px |
| Desktop | 1024–1279px | 12 | 32px |
| Wide | 1280px+ | 12 | 32px |

### Whitespace Philosophy
Space is structural, not decorative. Use the minimum spacing that maintains clear visual grouping. Dense is good — overwhelming is not. When in doubt, go one step tighter.

### Border Radius Scale
| Token | Value | Usage |
|-------|-------|-------|
| radius-sm | 2px | Badges, small tags |
| radius-md | 4px | Buttons, inputs, default |
| radius-lg | 6px | Cards, containers |
| radius-full | 9999px | Pills, avatars |

## 6. Depth & Elevation

| Level | Name | Shadow Value | Usage |
|-------|------|-------------|-------|
| 0 | Flat | `none` | Default state, inline elements |
| 1 | Raised | `0 1px 3px rgba(0, 0, 0, 0.4)` | Cards at rest, nav bar |
| 2 | Elevated | `0 4px 12px rgba(0, 0, 0, 0.5)` | Dropdowns, hover cards |
| 3 | Overlay | `0 8px 24px rgba(0, 0, 0, 0.6), 0 0 0 1px rgba(255,255,255,0.05)` | Modals, command palettes, tooltips |
| Glow | Focus | `0 0 0 3px rgba(34, 211, 238, 0.15)` | Focus rings on interactive elements |

**Elevation principles:**
- Dark mode relies on border + subtle background shifts more than shadow for hierarchy
- Shadows should feel like absence of light, not presence of grey
- Glow effects replace traditional focus rings — they signal interactivity without breaking the dark aesthetic
- Never stack more than one shadow level on a single element

## 7. Do's and Don'ts

### Do's
1. **Do** use monospace fonts for data, IDs, timestamps, code, and anything machine-generated
2. **Do** rely on border colour shifts and background tints for hierarchy over heavy shadows
3. **Do** keep transitions to 150ms — fast enough to feel instant, slow enough to register
4. **Do** use the cyan accent sparingly — one primary action per viewport section maximum
5. **Do** maintain a minimum contrast ratio of 4.5:1 for body text and 3:1 for large text
6. **Do** use the `Surface 3` background (`#243044`) for hover and selected states in lists and tables
7. **Do** test all colour combinations against WCAG AA on the actual background they'll appear on

### Don'ts
1. **Don't** use gradients — this system is flat by conviction, not by laziness
2. **Don't** use more than two type weights on a single component (e.g., 400 + 600 is the max)
3. **Don't** round corners beyond 6px — sharp geometry is core to the identity
4. **Don't** use pure white (`#ffffff`) for text — `#e2e8f0` is the ceiling
5. **Don't** animate layout properties (width, height, margin) — only opacity, transform, colour, box-shadow
6. **Don't** use light-mode defaults and "invert" them — design natively for dark backgrounds
7. **Don't** place cyan text on surfaces lighter than `#1c2333` — contrast drops below acceptable levels

## 8. Responsive Behaviour

### Breakpoint Behaviour
| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 640px) | Single column. Navigation collapses to hamburger. Cards stack full-width. Code blocks gain horizontal scroll. Font sizes reduce by 1 step. |
| Tablet (640–1023px) | Two-column where applicable. Sidebar collapses to top tabs. Card grid becomes 2-up. |
| Desktop (1024–1279px) | Full layout. Sidebar visible. 3-column card grids. All navigation visible. |
| Wide (1280px+) | Content maxes at 1280px container. Extra space becomes margin. |

### Touch Targets
- Minimum: 44px × 44px tap area (even if visually smaller)
- Spacing between tappable elements: minimum 8px
- Mobile nav items: 48px minimum height

### Mobile-Specific Rules
- Code blocks: horizontal scroll with `-webkit-overflow-scrolling: touch`
- Tables: horizontal scroll wrapper with shadow fade indicators on edges
- Reduce card padding from 20px to 16px
- Stack side-by-side layouts at 640px breakpoint
- Increase body font to 16px to prevent iOS zoom

## 9. Agent Prompt Guide

### Quick Colour Reference
| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#22d3ee` | Primary actions, links, focus |
| `--color-primary-hover` | `#06b6d4` | Hover states for primary |
| `--color-accent` | `#a78bfa` | Secondary highlights, tags |
| `--color-bg` | `#0d1117` | Page background |
| `--color-surface-1` | `#161b22` | Cards, panels |
| `--color-surface-2` | `#1c2333` | Elevated elements |
| `--color-surface-3` | `#243044` | Active/selected states |
| `--color-text` | `#e2e8f0` | Primary text |
| `--color-text-secondary` | `#94a3b8` | Secondary text |
| `--color-text-tertiary` | `#475569` | Disabled, placeholders |
| `--color-border` | `#1e293b` | Default borders |
| `--color-success` | `#4ade80` | Success states |
| `--color-warning` | `#fbbf24` | Warning states |
| `--color-error` | `#f87171` | Error states |
| `--font-mono` | `'JetBrains Mono', 'Fira Code', monospace` | Code, data |
| `--font-sans` | `'Inter', system-ui, sans-serif` | UI, prose |
| `--radius-default` | `4px` | Standard radius |

### Ready-to-Use Prompts

**Prompt 1 — Full page build:**
> Build a dashboard page using the Agency Techie design system. Dark background (#0d1117), cards on #161b22 with 1px #1e293b borders and 6px radius. Primary accent is #22d3ee. Use JetBrains Mono for all data/metrics and Inter for labels and descriptions. Navigation bar at 56px height with #94a3b8 nav text. Dense 16px card gaps.

**Prompt 2 — Component build:**
> Create a data table component. Background #161b22, header row #1c2333, row hover #243044. Text in #e2e8f0, secondary columns in #94a3b8. Borders 1px #1e293b. Use JetBrains Mono 14px for data cells, Inter 12px/500 for column headers. Sort indicators in #22d3ee.

**Prompt 3 — Form build:**
> Design a settings form. Inputs: #161b22 background, 1px #1e293b border, 4px radius, 14px Inter. Focus state: #22d3ee border with 0 0 0 3px rgba(34,211,238,0.1) glow. Labels: 12px Inter 500 #94a3b8. Primary submit button: #22d3ee background, #0d1117 text, 500 weight.

**Prompt 4 — API documentation page:**
> Build an API reference page. Left sidebar navigation on #161b22, content area on #0d1117. Endpoint methods (GET, POST) as badges with 2px radius — GET in #4ade80 text on rgba(74,222,128,0.1), POST in #60a5fa on rgba(96,165,250,0.1). Code examples in JetBrains Mono 14px on #161b22 blocks with #1e293b borders. Response fields in a data table.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
