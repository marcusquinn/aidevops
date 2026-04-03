# Design System: Corporate Traditional

## 1. Visual Theme & Atmosphere

This design system embodies institutional authority, trustworthiness, and time-tested professionalism. It draws from the visual language of established organisations — law firms, financial institutions, government agencies, and universities — where credibility is communicated through restraint, structure, and classical typographic choices.

The palette centres on deep navy blue paired with measured gold accents, set against clean light backgrounds. Every element is designed to convey stability and competence. There is no trend-chasing here; the aesthetic is deliberately conservative, favouring proven patterns over novel experimentation. Decoration is minimal and always purposeful.

Visual hierarchy is achieved through typographic scale and weight rather than colour saturation or animation. Serif headings lend gravitas, while sans-serif body text ensures readability across long documents. The overall impression should feel like a well-bound annual report: structured, polished, and reassuringly predictable.

**Key characteristics:**
- **Mood:** Authoritative, trustworthy, conservative, stable
- **Primary colour:** Navy blue `#1B365D`
- **Accent colour:** Gold `#B8860B`
- **Background:** White `#FFFFFF` with light grey sections `#F5F5F0`
- **Border treatment:** 1px solid `#D1D5DB`, rarely rounded
- **Animation:** Minimal — opacity fades only, 200ms ease
- **Imagery style:** Professional photography, muted tones, no illustrations
- **Overall density:** Medium-high — efficient use of space without crowding

## 2. Colour Palette & Roles

### Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#1B365D` | Headers, primary buttons, navigation background |
| Primary Light | `#2A4A7F` | Hover states, secondary elements |
| Primary Dark | `#0F2341` | Active states, footer background |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Gold | `#B8860B` | CTAs, highlights, award badges, key links |
| Gold Light | `#D4A843` | Hover on gold elements |
| Gold Muted | `#C9B97A` | Decorative borders, subtle highlights |

### Text

| Role | Hex | Usage |
|------|-----|-------|
| Heading | `#1B365D` | All headings h1–h6 |
| Body | `#333333` | Paragraph text, descriptions |
| Secondary | `#6B7280` | Captions, metadata, timestamps |
| Inverse | `#FFFFFF` | Text on dark backgrounds |

### Surface

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FFFFFF` | Page background |
| Surface Alt | `#F5F5F0` | Alternating sections, sidebar |
| Surface Accent | `#EEF0F4` | Card backgrounds, table headers |
| Border | `#D1D5DB` | Dividers, table borders, input borders |
| Border Strong | `#9CA3AF` | Active input borders |

### Semantic

| Role | Hex | Usage |
|------|-----|-------|
| Success | `#166534` | Confirmations, positive indicators |
| Warning | `#92400E` | Caution messages |
| Error | `#991B1B` | Error states, required fields |
| Info | `#1E40AF` | Informational callouts |

### Shadows

| Role | Value | Usage |
|------|-------|-------|
| Shadow colour | `rgba(27, 54, 93, 0.08)` | All shadow definitions |
| Shadow strong | `rgba(27, 54, 93, 0.15)` | Elevated elements |

## 3. Typography Rules

**Font families:**
- **Headings:** `Georgia, "Times New Roman", "Noto Serif", serif`
- **Body:** `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
- **Monospace:** `"SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace`

### Hierarchy

| Role | Font | Size | Weight | Line-Height | Letter-Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Serif | 48px / 3rem | 400 | 1.2 | -0.02em | Hero sections only |
| H1 | Serif | 36px / 2.25rem | 700 | 1.25 | -0.01em | Page titles |
| H2 | Serif | 28px / 1.75rem | 700 | 1.3 | -0.005em | Section headers |
| H3 | Serif | 22px / 1.375rem | 700 | 1.35 | 0 | Subsection headers |
| H4 | Sans-serif | 18px / 1.125rem | 600 | 1.4 | 0.01em | Card titles, labels |
| Body | Sans-serif | 16px / 1rem | 400 | 1.6 | 0 | Default paragraph |
| Body Small | Sans-serif | 14px / 0.875rem | 400 | 1.5 | 0.005em | Secondary content |
| Caption | Sans-serif | 12px / 0.75rem | 400 | 1.4 | 0.02em | Metadata, footnotes |
| Overline | Sans-serif | 11px / 0.6875rem | 600 | 1.2 | 0.1em | Labels, categories (uppercase) |

**Principles:**
- Serif headings always pair with sans-serif body — never mix within the same role
- Headings use sentence case, never all-caps except for `Overline`
- Minimum body text size: 16px on desktop, 15px on mobile
- Maximum line length: 75 characters (approximately 680px at 16px)

## 4. Component Stylings

### Buttons

**Primary Button:**
```
background: #1B365D
color: #FFFFFF
padding: 12px 28px
border: none
border-radius: 4px
font-family: system-ui, sans-serif
font-size: 15px
font-weight: 600
letter-spacing: 0.02em
text-transform: none
cursor: pointer
transition: background 200ms ease

:hover    → background: #2A4A7F
:active   → background: #0F2341
:focus    → outline: 2px solid #B8860B; outline-offset: 2px
:disabled → background: #9CA3AF; cursor: not-allowed
```

**Secondary Button:**
```
background: transparent
color: #1B365D
padding: 12px 28px
border: 1.5px solid #1B365D
border-radius: 4px
font-size: 15px
font-weight: 600

:hover    → background: #EEF0F4
:active   → background: #D1D5DB
:disabled → border-color: #D1D5DB; color: #9CA3AF
```

**Ghost Button:**
```
background: transparent
color: #1B365D
padding: 12px 28px
border: none
border-radius: 4px
font-size: 15px
font-weight: 600
text-decoration: underline
text-underline-offset: 3px

:hover    → color: #2A4A7F; background: #F5F5F0
:active   → color: #0F2341
```

### Inputs

```
background: #FFFFFF
border: 1px solid #D1D5DB
border-radius: 4px
padding: 10px 14px
font-family: system-ui, sans-serif
font-size: 16px
color: #333333
transition: border-color 200ms ease

:hover       → border-color: #9CA3AF
:focus       → border-color: #1B365D; box-shadow: 0 0 0 3px rgba(27, 54, 93, 0.12)
:error       → border-color: #991B1B; box-shadow: 0 0 0 3px rgba(153, 27, 27, 0.1)
::placeholder → color: #9CA3AF
:disabled    → background: #F5F5F0; color: #9CA3AF
```

**Labels:** 14px, weight 600, colour `#333333`, margin-bottom 6px.

### Links

```
color: #1B365D
text-decoration: underline
text-underline-offset: 3px
text-decoration-color: #D1D5DB
transition: text-decoration-color 200ms ease

:hover  → text-decoration-color: #1B365D
:active → color: #0F2341
```

Gold accent links (CTAs): `color: #B8860B`, same underline treatment.

### Cards

```
background: #FFFFFF
border: 1px solid #D1D5DB
border-radius: 4px
padding: 24px 28px
box-shadow: 0 1px 3px rgba(27, 54, 93, 0.06)

:hover → box-shadow: 0 2px 8px rgba(27, 54, 93, 0.1) (if interactive)
```

### Navigation

```
Top bar:
  background: #1B365D
  color: #FFFFFF
  height: 64px
  padding: 0 32px
  font-size: 14px
  font-weight: 500
  letter-spacing: 0.02em

Nav links:
  color: rgba(255, 255, 255, 0.85)
  :hover → color: #FFFFFF; border-bottom: 2px solid #B8860B
  :active → color: #FFFFFF; border-bottom: 2px solid #FFFFFF

Dropdown:
  background: #FFFFFF
  border: 1px solid #D1D5DB
  box-shadow: 0 4px 12px rgba(27, 54, 93, 0.12)
  border-radius: 4px
```

## 5. Layout Principles

### Spacing Scale

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

### Grid

- 12-column grid
- Column gap: 24px (desktop), 16px (tablet)
- Max container width: 1200px
- Content area: centred with `margin: 0 auto`
- Sidebar layout: 3 columns sidebar / 9 columns content (desktop)

### Container Widths

| Breakpoint | Container | Side Padding |
|-----------|-----------|-------------|
| ≥1280px | 1200px (fixed) | auto |
| 1024–1279px | 100% | 48px |
| 768–1023px | 100% | 32px |
| <768px | 100% | 20px |

### Whitespace Philosophy

Space is used to convey structure and hierarchy. Sections are clearly delineated with generous vertical margins (48–96px). Content blocks within sections use 24–32px spacing. Tight spacing (4–8px) is reserved for inline elements and related content groups.

### Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 2px | Tags, badges |
| `--radius-md` | 4px | Buttons, inputs, cards |
| `--radius-lg` | 6px | Modals, dropdowns |
| `--radius-full` | 9999px | Avatars only |

## 6. Depth & Elevation

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Default state, inline elements |
| 1 | Raised | `0 1px 3px rgba(27, 54, 93, 0.06), 0 1px 2px rgba(27, 54, 93, 0.04)` | Cards, form containers |
| 2 | Elevated | `0 4px 12px rgba(27, 54, 93, 0.08), 0 2px 4px rgba(27, 54, 93, 0.04)` | Hover cards, popovers |
| 3 | Overlay | `0 12px 28px rgba(27, 54, 93, 0.12), 0 4px 8px rgba(27, 54, 93, 0.06)` | Modals, dropdown menus |
| 4 | Modal | `0 20px 40px rgba(27, 54, 93, 0.16), 0 8px 16px rgba(27, 54, 93, 0.08)` | Full-screen overlays |

**Elevation principles:**
- Use elevation sparingly — flat is the default
- Maximum two elevation levels visible simultaneously
- Never apply shadows to inline text elements
- Modal backdrop: `rgba(15, 35, 65, 0.5)`

## 7. Do's and Don'ts

### Do's

1. **Do** use the navy/gold palette consistently — navy for structure, gold for emphasis
2. **Do** maintain strict vertical rhythm with the spacing scale
3. **Do** use serif headings to establish authority and hierarchy
4. **Do** keep animations minimal and functional (200ms opacity/colour transitions only)
5. **Do** use the 12-column grid for all layout decisions
6. **Do** ensure all interactive elements have visible focus states with the gold outline
7. **Do** use white space generously between major sections (48px minimum)
8. **Do** maintain a clear document hierarchy: one H1 per page, sequential heading levels

### Don'ts

1. **Don't** use gradients, background patterns, or decorative illustrations
2. **Don't** round corners beyond 6px — this is not a playful design system
3. **Don't** use bright or saturated colours outside the semantic palette
4. **Don't** animate layout properties (size, position) — only opacity and colour
5. **Don't** use all-caps for body text or headings (only for overline labels)
6. **Don't** stack more than two font weights on a single screen section
7. **Don't** use icon-only buttons without accessible labels
8. **Don't** place gold (#B8860B) text on white backgrounds — insufficient contrast for body text

## 8. Responsive Behaviour

### Breakpoints

| Name | Range | Columns | Gutter | Behaviour |
|------|-------|---------|--------|-----------|
| Mobile | 0–767px | 4 | 16px | Single column, stacked layout |
| Tablet | 768–1023px | 8 | 16px | Sidebar collapses, 2-col grids |
| Desktop | 1024–1279px | 12 | 24px | Full layout, sidebar visible |
| Wide | ≥1280px | 12 | 24px | Centred container, max 1200px |

### Touch Targets

- Minimum tap target: 44×44px
- Minimum spacing between tap targets: 8px
- Mobile button padding: minimum 14px vertical

### Mobile-Specific Rules

- Navigation collapses to hamburger menu at <768px
- Sidebar content moves below main content
- Tables become horizontally scrollable with `-webkit-overflow-scrolling: touch`
- Font sizes reduce: H1 → 28px, H2 → 22px, Body remains 16px
- Section vertical padding reduces by ~33% (e.g., 96px → 64px)
- Cards stack full-width with 16px gap
- Gold accent elements maintain visibility — do not hide on mobile

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#1B365D` | Navy blue — headers, nav, primary buttons |
| `--color-primary-light` | `#2A4A7F` | Hover states |
| `--color-primary-dark` | `#0F2341` | Active states, footer |
| `--color-accent` | `#B8860B` | Gold — CTAs, highlights, key links |
| `--color-accent-light` | `#D4A843` | Gold hover |
| `--color-text` | `#333333` | Body text |
| `--color-text-heading` | `#1B365D` | Headings |
| `--color-text-secondary` | `#6B7280` | Captions, metadata |
| `--color-surface` | `#FFFFFF` | Page background |
| `--color-surface-alt` | `#F5F5F0` | Alternate sections |
| `--color-border` | `#D1D5DB` | Borders, dividers |
| `--color-success` | `#166534` | Success states |
| `--color-warning` | `#92400E` | Warning states |
| `--color-error` | `#991B1B` | Error states |

### Ready-to-Use Prompts

**Prompt 1 — Full page layout:**
> Build a landing page following DESIGN.md. Use the navy (#1B365D) top navigation bar at 64px height with white text. Hero section has a serif H1 (Georgia, 48px) on a #F5F5F0 background with 96px vertical padding. Below, a 3-column feature grid using cards with 1px #D1D5DB borders and 4px border-radius. Primary CTA button in navy with gold (#B8860B) accent for the secondary action. Footer in #0F2341 with white text.

**Prompt 2 — Form page:**
> Create a multi-step form page following DESIGN.md. White background, centred container at 680px max-width. Each input has a 1px #D1D5DB border, 4px radius, and transitions to #1B365D border on focus with a 3px navy ring. Labels are 14px weight-600 in #333333. Primary submit button in #1B365D, secondary cancel in outlined style. Error states use #991B1B borders with inline error messages below fields.

**Prompt 3 — Dashboard layout:**
> Build a dashboard following DESIGN.md. Left sidebar (280px) in #1B365D with white navigation links. Main content area on #F5F5F0 background. Stat cards in white with 1px borders and raised shadow (0 1px 3px rgba(27,54,93,0.06)). Data tables use #EEF0F4 header rows, alternating white/#F5F5F0 body rows, and 1px #D1D5DB borders. Gold (#B8860B) for key metric highlights and important action buttons.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
