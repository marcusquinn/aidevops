# Design System: Corporate Modern

## 1. Visual Theme & Atmosphere

This design system represents the contemporary enterprise — confident, clean, and forward-looking without sacrificing professionalism. It targets the visual tier occupied by modern SaaS platforms, fintech companies, and tech-forward professional services. The aesthetic communicates competence through clarity rather than ornamentation.

The foundation is a high-contrast pairing of near-black charcoal text on pristine white surfaces, energised by a teal accent that signals innovation without frivolity. The design relies on an 8px spacing grid that creates mathematical consistency across every component, lending the interface a precision that users feel even if they cannot articulate it.

Typography is uniform — a single sans-serif family (Inter or system-ui) handles all roles, with hierarchy established purely through size, weight, and colour. Shadows are subtle and purposeful, suggesting depth without drama. The overall effect is a workspace that feels both spacious and efficient: every pixel earns its place.

**Key characteristics:**
- **Mood:** Confident, clean, contemporary, efficient
- **Primary text:** Charcoal `#1a1a2e`
- **Accent colour:** Teal `#0891b2`
- **Background:** White `#FFFFFF`
- **Spacing grid:** 8px base unit
- **Border treatment:** 1px solid `#E2E8F0`, 8px radius default
- **Animation:** 150ms ease-out transitions on colour and shadow
- **Imagery style:** Abstract gradients, product screenshots, clean iconography
- **Overall density:** Medium — balanced between information and breathing room

## 2. Colour Palette & Roles

### Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#0891b2` | CTAs, active states, links, accent elements |
| Primary Light | `#22d3ee` | Hover highlights, badges, progress bars |
| Primary Dark | `#0e7490` | Active/pressed states |
| Primary Subtle | `#ecfeff` | Tinted backgrounds, selected row highlights |

### Neutral

| Role | Hex | Usage |
|------|-----|-------|
| Charcoal | `#1a1a2e` | Headings, primary text |
| Body | `#334155` | Paragraph text |
| Secondary | `#64748b` | Captions, helper text, placeholders |
| Tertiary | `#94a3b8` | Disabled text, deemphasised labels |
| Border | `#E2E8F0` | Dividers, input borders, card borders |
| Border Strong | `#CBD5E1` | Active borders, hover states |

### Surface

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FFFFFF` | Page background |
| Surface | `#F8FAFC` | Card backgrounds, sidebar, alternate rows |
| Surface Elevated | `#FFFFFF` | Floating elements (with shadow) |
| Overlay | `rgba(26, 26, 46, 0.4)` | Modal backdrops |

### Semantic

| Role | Hex | Background | Usage |
|------|-----|-----------|-------|
| Success | `#059669` | `#ecfdf5` | Confirmations, complete states |
| Warning | `#d97706` | `#fffbeb` | Caution, pending states |
| Error | `#dc2626` | `#fef2f2` | Errors, destructive actions |
| Info | `#0891b2` | `#ecfeff` | Informational, tips |

## 3. Typography Rules

**Font families:**
- **All text:** `Inter, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
- **Monospace:** `"JetBrains Mono", "Fira Code", "SFMono-Regular", Consolas, monospace`

### Hierarchy

| Role | Size | Weight | Line-Height | Letter-Spacing | Colour | Notes |
|------|------|--------|-------------|----------------|--------|-------|
| Display | 56px / 3.5rem | 700 | 1.1 | -0.025em | `#1a1a2e` | Marketing heroes only |
| H1 | 40px / 2.5rem | 700 | 1.2 | -0.02em | `#1a1a2e` | Page titles |
| H2 | 32px / 2rem | 600 | 1.25 | -0.015em | `#1a1a2e` | Section headers |
| H3 | 24px / 1.5rem | 600 | 1.3 | -0.01em | `#1a1a2e` | Subsections |
| H4 | 20px / 1.25rem | 600 | 1.35 | -0.005em | `#1a1a2e` | Card headers |
| Body Large | 18px / 1.125rem | 400 | 1.6 | 0 | `#334155` | Lead paragraphs |
| Body | 16px / 1rem | 400 | 1.6 | 0 | `#334155` | Default text |
| Body Small | 14px / 0.875rem | 400 | 1.5 | 0.005em | `#334155` | Compact layouts |
| Caption | 12px / 0.75rem | 500 | 1.4 | 0.02em | `#64748b` | Labels, metadata |
| Overline | 12px / 0.75rem | 600 | 1.2 | 0.08em | `#64748b` | Section labels (uppercase) |

**Principles:**
- One font family for everything — hierarchy comes from size and weight only
- Negative letter-spacing on headings (tighter), positive on small text (looser)
- Maximum content width: 720px for long-form text
- Use weight 500 (medium) sparingly — primarily for emphasis within body text

## 4. Component Stylings

### Buttons

**Primary Button:**
```
background: #0891b2
color: #FFFFFF
padding: 10px 24px
border: none
border-radius: 8px
font-size: 15px
font-weight: 600
line-height: 1.4
cursor: pointer
transition: all 150ms ease-out

:hover    → background: #0e7490; box-shadow: 0 2px 8px rgba(8, 145, 178, 0.25)
:active   → background: #155e75; transform: translateY(0.5px)
:focus    → outline: 2px solid #0891b2; outline-offset: 2px
:disabled → background: #E2E8F0; color: #94a3b8; cursor: not-allowed
```

**Secondary Button:**
```
background: #FFFFFF
color: #1a1a2e
padding: 10px 24px
border: 1px solid #E2E8F0
border-radius: 8px
font-size: 15px
font-weight: 600

:hover    → border-color: #CBD5E1; background: #F8FAFC
:active   → background: #E2E8F0
:disabled → color: #94a3b8; border-color: #E2E8F0
```

**Ghost Button:**
```
background: transparent
color: #0891b2
padding: 10px 24px
border: none
border-radius: 8px
font-size: 15px
font-weight: 600

:hover    → background: #ecfeff
:active   → background: #cffafe
```

### Inputs

```
background: #FFFFFF
border: 1px solid #E2E8F0
border-radius: 8px
padding: 10px 14px
font-size: 15px
color: #1a1a2e
transition: border-color 150ms ease-out, box-shadow 150ms ease-out

:hover       → border-color: #CBD5E1
:focus       → border-color: #0891b2; box-shadow: 0 0 0 3px rgba(8, 145, 178, 0.12)
:error       → border-color: #dc2626; box-shadow: 0 0 0 3px rgba(220, 38, 38, 0.08)
::placeholder → color: #94a3b8
:disabled    → background: #F8FAFC; color: #94a3b8; border-color: #E2E8F0
```

**Labels:** 14px, weight 500, colour `#1a1a2e`, margin-bottom 6px.
**Helper text:** 13px, weight 400, colour `#64748b`, margin-top 4px.

### Links

```
color: #0891b2
text-decoration: none
font-weight: 500
transition: color 150ms ease-out

:hover  → color: #0e7490; text-decoration: underline; text-underline-offset: 3px
:active → color: #155e75
```

### Cards

```
background: #FFFFFF
border: 1px solid #E2E8F0
border-radius: 12px
padding: 24px
transition: box-shadow 150ms ease-out, border-color 150ms ease-out

Interactive cards:
:hover → border-color: #CBD5E1; box-shadow: 0 4px 12px rgba(26, 26, 46, 0.06)
```

### Navigation

```
Top bar:
  background: #FFFFFF
  border-bottom: 1px solid #E2E8F0
  height: 64px
  padding: 0 24px

Nav links:
  color: #64748b
  font-size: 14px
  font-weight: 500
  :hover  → color: #1a1a2e
  :active → color: #0891b2; font-weight: 600

Mobile nav:
  Slide-in from left, 280px wide
  background: #FFFFFF
  box-shadow: 4px 0 16px rgba(26, 26, 46, 0.08)
```

## 5. Layout Principles

### Spacing Scale (8px grid)

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline icon gaps, tight pairs |
| `--space-2` | 8px | Compact element spacing |
| `--space-3` | 12px | Input internal padding |
| `--space-4` | 16px | Standard gap, card gap |
| `--space-5` | 24px | Card padding, form field gaps |
| `--space-6` | 32px | Section internal padding |
| `--space-7` | 48px | Section breaks |
| `--space-8` | 64px | Major section separation |
| `--space-9` | 80px | Hero vertical padding |
| `--space-10` | 120px | Page-level vertical breathing room |

### Grid

- 12-column grid, 24px gutter
- All spacing values must be multiples of 8px (4px for fine adjustments)
- Flex and CSS Grid preferred over float layouts

### Container Widths

| Breakpoint | Container | Behaviour |
|-----------|-----------|-----------|
| ≥1440px | 1280px | Centred, fixed max-width |
| 1024–1439px | 100% - 96px | Fluid with 48px side padding |
| 768–1023px | 100% - 64px | Fluid with 32px side padding |
| <768px | 100% - 40px | Fluid with 20px side padding |

### Whitespace Philosophy

Whitespace is a first-class design element. Components breathe — generous padding inside cards (24px), meaningful gaps between sections (48–80px), and never less than 16px between distinct interactive elements. Dense UI is acceptable in data tables but nowhere else.

### Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 4px | Tags, small badges |
| `--radius-md` | 8px | Buttons, inputs, small cards |
| `--radius-lg` | 12px | Cards, containers |
| `--radius-xl` | 16px | Modals, feature cards |
| `--radius-full` | 9999px | Pills, avatars, toggles |

## 6. Depth & Elevation

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Default cards (use border instead) |
| 1 | Raised | `0 1px 3px rgba(26, 26, 46, 0.04), 0 1px 2px rgba(26, 26, 46, 0.03)` | Subtle card lift |
| 2 | Elevated | `0 4px 12px rgba(26, 26, 46, 0.06), 0 2px 4px rgba(26, 26, 46, 0.03)` | Hover cards, floating toolbar |
| 3 | Overlay | `0 8px 24px rgba(26, 26, 46, 0.08), 0 4px 8px rgba(26, 26, 46, 0.04)` | Dropdowns, popovers |
| 4 | Modal | `0 16px 48px rgba(26, 26, 46, 0.12), 0 8px 16px rgba(26, 26, 46, 0.06)` | Modals, command palettes |

**Elevation principles:**
- Default cards use border, not shadow — shadow appears on hover
- Shadows use the charcoal base colour for tint consistency
- Never combine border and heavy shadow on the same element
- Modal backdrop: `rgba(26, 26, 46, 0.4)` with `backdrop-filter: blur(4px)`

## 7. Do's and Don'ts

### Do's

1. **Do** maintain the 8px spacing grid rigorously — every margin and padding should be a multiple of 8 (4 for fine adjustments)
2. **Do** use the teal accent sparingly — it marks primary actions and key navigation, not decoration
3. **Do** rely on whitespace and typography weight for hierarchy, not colour variation
4. **Do** ensure all interactive elements have clear hover, focus, and disabled states
5. **Do** use consistent border-radius within component groups (8px for form elements, 12px for cards)
6. **Do** keep the navigation bar clean — no more than 6 top-level items
7. **Do** use the semantic colour palette for all status indicators
8. **Do** test all layouts at every breakpoint — no component should break between 320px and 1440px

### Don'ts

1. **Don't** use more than three font weights on a single view (400, 500/600, 700)
2. **Don't** apply the teal accent to large background areas — it's for interactive elements and small highlights only
3. **Don't** use drop shadows on flat elements like dividers or inline badges
4. **Don't** mix border-radius values within the same component (e.g., 8px top, 12px bottom)
5. **Don't** use colour alone to convey meaning — always pair with text, icons, or patterns
6. **Don't** place body text directly on coloured backgrounds without checking contrast (minimum WCAG AA 4.5:1)
7. **Don't** animate layout properties (width, height, margin) — only transform, opacity, colour, and box-shadow
8. **Don't** nest cards within cards — flatten the information hierarchy instead

## 8. Responsive Behaviour

### Breakpoints

| Name | Range | Columns | Gutter | Container Padding |
|------|-------|---------|--------|-------------------|
| Mobile | 0–767px | 4 | 16px | 20px |
| Tablet | 768–1023px | 8 | 24px | 32px |
| Desktop | 1024–1439px | 12 | 24px | 48px |
| Wide | ≥1440px | 12 | 24px | auto (centred 1280px) |

### Touch Targets

- Minimum tap target: 44×44px
- Minimum gap between targets: 8px
- Mobile buttons: full-width below 480px viewport
- Mobile inputs: minimum 48px height

### Mobile-Specific Rules

- Top navigation becomes a bottom tab bar (max 5 items) or hamburger menu
- Multi-column layouts collapse to single column at <768px
- Cards maintain 16px padding on mobile (down from 24px)
- Typography: H1 → 32px, H2 → 26px, H3 → 20px; body remains 16px
- Horizontal scrolling is only acceptable for data tables and carousels with scroll indicators
- Floating action buttons: 56px diameter, 16px from bottom-right
- Section vertical padding: reduce by ~25% from desktop values
- Sticky header height reduces to 56px on mobile

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#0891b2` | Teal — CTAs, links, active states |
| `--color-primary-light` | `#22d3ee` | Hover accents, badges |
| `--color-primary-dark` | `#0e7490` | Active/pressed states |
| `--color-primary-subtle` | `#ecfeff` | Tinted backgrounds |
| `--color-text` | `#1a1a2e` | Headings, primary text |
| `--color-text-body` | `#334155` | Paragraph text |
| `--color-text-secondary` | `#64748b` | Captions, metadata |
| `--color-text-tertiary` | `#94a3b8` | Disabled, placeholders |
| `--color-surface` | `#FFFFFF` | Page background |
| `--color-surface-alt` | `#F8FAFC` | Alternate surfaces |
| `--color-border` | `#E2E8F0` | Default borders |
| `--color-border-strong` | `#CBD5E1` | Hover/active borders |
| `--color-success` | `#059669` | Success states |
| `--color-warning` | `#d97706` | Warning states |
| `--color-error` | `#dc2626` | Error states |

### Ready-to-Use Prompts

**Prompt 1 — SaaS landing page:**
> Build a SaaS landing page following DESIGN.md. White (#FFFFFF) background with a clean top navbar (white, 64px, 1px bottom border #E2E8F0). Hero section with a 56px/700 heading in #1a1a2e, 18px body text in #334155, and a teal (#0891b2) primary CTA button with 8px radius. Below, a 3-column feature grid with 12px-radius cards on #F8FAFC backgrounds. Use the 8px spacing grid throughout. Testimonial section on white with raised shadow cards. Footer in #1a1a2e with white text.

**Prompt 2 — Settings/admin page:**
> Create an admin settings page following DESIGN.md. Left sidebar (260px) on #F8FAFC with #E2E8F0 right border. Navigation items are 14px/500 in #64748b, active item in #0891b2 with #ecfeff background and 8px radius. Main content area on white with a 720px max-width form. Group related fields with 24px gaps, sections separated by 1px #E2E8F0 dividers. Inputs have #E2E8F0 borders, 8px radius, focus ring in teal. Save button in #0891b2, cancel in outlined secondary style.

**Prompt 3 — Data dashboard:**
> Build a data dashboard following DESIGN.md. Top navbar (64px, white, border-bottom #E2E8F0) with the product name in #1a1a2e/600 and teal notification badge. Main grid on #F8FAFC: KPI cards (white, 12px radius, border #E2E8F0) showing metrics in 32px/700 charcoal with trend arrows in #059669 or #dc2626. Chart containers are white cards with 24px padding. Data table with #F8FAFC header row, 14px/500 column headers in #64748b, and 16px/400 body cells in #334155 with alternating row shading.

**Prompt 4 — Pricing page:**
> Create a pricing page following DESIGN.md. Three pricing cards in a row (12px radius, #E2E8F0 border). The recommended plan has a teal (#0891b2) top border (3px) and a subtle #ecfeff background. Plan names in 24px/600, prices in 40px/700 #1a1a2e. Feature lists use 14px with #059669 checkmarks. CTA buttons: recommended plan gets primary teal, others get secondary outlined. Below, FAQ in accordion style with 1px dividers.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
