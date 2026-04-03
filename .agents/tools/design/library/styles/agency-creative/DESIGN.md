# Design System: Agency Creative

## 1. Visual Theme & Atmosphere

Agency Creative is a bold, expressive design system for teams that lead with visual storytelling. It takes cues from high-end editorial design, motion graphics, and the unapologetic confidence of studios that win awards. Colour is not decoration — it's the message. Typography is not just readable — it commands the room.

The palette is built around a vibrant purple-to-pink gradient axis with deep dark surfaces that let colour work hard. When used on light backgrounds, the same palette shifts to high-impact contrast against clean whites. Every surface is a potential canvas: gradients can sweep across hero sections, buttons pulse with colour, and empty space becomes dramatic tension.

Layout philosophy is deliberately asymmetric. Grids are a scaffold, not a cage — elements can break columns, overlap, and create intentional visual friction. Motion is a core design element, not an afterthought. Page transitions, scroll-triggered animations, and micro-interactions give the system its energy. Type is large, tracked wide, and demands attention.

**Key characteristics:**
- **Mood:** Bold, dynamic, confident, expressive, editorial
- **Signature gradient:** Purple `#7c3aed` → Pink `#ec4899` (135° angle default)
- **Background options:** Deep black `#0f0f0f` (dark mode), clean white `#ffffff` (light mode)
- **Typography feel:** Large display type, wide tracking, strong hierarchy
- **Corner treatment:** Mixed — 16px for containers, 999px for CTAs (pill), 0px for editorial crops
- **Border style:** Minimal — rely on colour and spacing for structure, not lines
- **Shadow approach:** Coloured shadows that extend the gradient palette
- **Density:** Low to medium — generous whitespace creates drama
- **Motion:** Core element — 300–500ms spring easing, scroll-triggered reveals, hover transforms

## 2. Colour Palette & Roles

### Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#7c3aed` | Buttons, key links, active states |
| Primary Light | `#a78bfa` | Hover states, secondary emphasis |
| Primary Dark | `#5b21b6` | Active/pressed states |
| Primary Gradient | `linear-gradient(135deg, #7c3aed, #ec4899)` | Hero sections, primary CTAs, feature highlights |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Accent | `#ec4899` | Secondary actions, highlights, gradient endpoint |
| Accent Light | `#f472b6` | Hover variant |
| Accent Dark | `#be185d` | Active variant |
| Tertiary | `#f59e0b` | Occasional warm pop — awards, stars, limited use |

### Text (Dark Mode)

| Role | Hex | Usage |
|------|-----|-------|
| Text Primary | `#f8fafc` | Headings, primary body |
| Text Secondary | `#a1a1aa` | Descriptions, captions |
| Text Tertiary | `#52525b` | Placeholders, metadata |
| Text On Gradient | `#ffffff` | Text over gradient backgrounds |

### Text (Light Mode)

| Role | Hex | Usage |
|------|-----|-------|
| Text Primary | `#0f0f0f` | Headings, primary body |
| Text Secondary | `#52525b` | Descriptions, captions |
| Text Tertiary | `#a1a1aa` | Placeholders, metadata |

### Surface (Dark Mode)

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#0f0f0f` | Page background |
| Surface 1 | `#18181b` | Cards, sections |
| Surface 2 | `#27272a` | Elevated cards, dropdowns |
| Surface 3 | `#3f3f46` | Active states, hover backgrounds |
| Border Default | `#27272a` | Subtle borders where needed |
| Border Accent | `#7c3aed` | Active/focused borders |

### Surface (Light Mode)

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#ffffff` | Page background |
| Surface 1 | `#fafafa` | Cards, sections |
| Surface 2 | `#f4f4f5` | Elevated elements |
| Border Default | `#e4e4e7` | Subtle borders |

### Semantic

| Role | Hex | Usage |
|------|-----|-------|
| Success | `#34d399` | Confirmations, sent states |
| Warning | `#fbbf24` | Caution, review needed |
| Error | `#f87171` | Errors, destructive actions |
| Info | `#60a5fa` | Help text, informational |

### Shadows

| Role | Value | Usage |
|------|-------|-------|
| Gradient Glow | `0 8px 32px rgba(124, 58, 237, 0.3)` | Primary CTAs, hero elements |
| Pink Glow | `0 8px 32px rgba(236, 72, 153, 0.25)` | Accent elements, hover effects |
| Dark Lift | `0 4px 24px rgba(0, 0, 0, 0.5)` | Cards in dark mode |
| Light Lift | `0 4px 24px rgba(0, 0, 0, 0.08)` | Cards in light mode |

## 3. Typography Rules

### Font Families

| Role | Stack |
|------|-------|
| Display | `'Space Grotesk', 'Plus Jakarta Sans', system-ui, sans-serif` |
| Body | `'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif` |
| Mono | `'JetBrains Mono', 'SF Mono', monospace` |

### Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display XL | Display | 80px | 700 | 1.0 | -0.04em | Hero headlines, maximum impact |
| Display | Display | 64px | 700 | 1.05 | -0.035em | Section heroes, landing statements |
| H1 | Display | 48px | 700 | 1.1 | -0.03em | Page titles |
| H2 | Display | 36px | 600 | 1.15 | -0.02em | Section headings |
| H3 | Display | 28px | 600 | 1.2 | -0.015em | Subsection headings |
| H4 | Display | 22px | 600 | 1.25 | -0.01em | Card titles |
| Overline | Body | 13px | 600 | 1.4 | 0.12em | Category labels, section tags (UPPERCASE) |
| Body Large | Body | 18px | 400 | 1.7 | -0.006em | Lead paragraphs, introductions |
| Body | Body | 16px | 400 | 1.65 | -0.006em | Primary reading text |
| Body Small | Body | 14px | 400 | 1.5 | 0 | Captions, secondary info |
| Label | Body | 12px | 500 | 1.4 | 0.04em | Form labels, metadata |
| Code | Mono | 14px | 400 | 1.6 | 0 | Code snippets, technical details |

### Typography Principles

- Display type (Space Grotesk) is reserved for headings and hero content — never body text
- Use UPPERCASE overlines sparingly to introduce sections with category context
- Headings at 64px+ can use the gradient as a text fill (`background-clip: text`) for maximum impact
- Body text stays in Inter for readability — never sacrifice legibility for style
- Track display type tighter as it gets larger (negative letter-spacing scales with size)

## 4. Component Stylings

### Buttons

**Primary Button (Gradient)**

```css
background: linear-gradient(135deg, #7c3aed, #ec4899)
color: #ffffff
font: 15px/1 Inter, 600
padding: 14px 32px
border: none
border-radius: 999px
box-shadow: 0 4px 16px rgba(124, 58, 237, 0.3)
transition: all 300ms cubic-bezier(0.34, 1.56, 0.64, 1)

:hover    → transform: translateY(-2px); box-shadow: 0 8px 32px rgba(124, 58, 237, 0.4)
:active   → transform: translateY(0); box-shadow: 0 2px 8px rgba(124, 58, 237, 0.3)
:focus    → outline: 2px solid #a78bfa; outline-offset: 3px
:disabled → opacity: 0.5; cursor: not-allowed; transform: none
```

**Secondary Button**

```css
background: transparent
color: #f8fafc (dark) / #0f0f0f (light)
font: 15px/1 Inter, 600
padding: 14px 32px
border: 2px solid #7c3aed
border-radius: 999px

:hover    → background: rgba(124, 58, 237, 0.1); transform: translateY(-1px)
:active   → background: rgba(124, 58, 237, 0.15)
:focus    → outline: 2px solid #a78bfa; outline-offset: 3px
:disabled → opacity: 0.5; cursor: not-allowed
```

**Ghost Button**

```css
background: transparent
color: #a1a1aa (dark) / #52525b (light)
font: 15px/1 Inter, 500
padding: 14px 32px
border: none
border-radius: 999px

:hover    → color: #f8fafc; background: rgba(255,255,255,0.05)
:active   → background: rgba(255,255,255,0.08)
```

### Inputs

```css
background: #18181b (dark) / #ffffff (light)
color: #f8fafc (dark) / #0f0f0f (light)
font: 15px Inter
padding: 14px 18px
border: 1px solid #27272a (dark) / #e4e4e7 (light)
border-radius: 12px

::placeholder → color: #52525b
:hover        → border-color: #3f3f46
:focus        → border-color: #7c3aed; box-shadow: 0 0 0 4px rgba(124, 58, 237, 0.15)
:invalid      → border-color: #f87171
```

### Links

```css
color: #a78bfa (dark) / #7c3aed (light)
text-decoration: none
font-weight: 500
transition: color 200ms ease

:hover  → color: #c4b5fd; text-decoration: underline
:active → color: #7c3aed
```

### Cards

```css
background: #18181b (dark) / #ffffff (light)
border: 1px solid #27272a (dark) / #e4e4e7 (light)
border-radius: 16px
padding: 32px
transition: transform 300ms cubic-bezier(0.34, 1.56, 0.64, 1), box-shadow 300ms ease

:hover → transform: translateY(-4px); box-shadow: 0 12px 40px rgba(0,0,0,0.3) (dark) / 0 12px 40px rgba(0,0,0,0.08) (light)
```

### Navigation

```css
Background: transparent (scrolled: #0f0f0f/95 with backdrop-blur: 16px)
Height: 72px
Logo: bold display wordmark or logomark, left-aligned
Nav items: 15px Inter, 500, #a1a1aa
Active item: #f8fafc with gradient underline
CTA in nav: pill button with gradient
```

## 5. Layout Principles

### Spacing Scale (8px base unit)

| Token | Value | Usage |
|-------|-------|-------|
| space-1 | 4px | Micro adjustments |
| space-2 | 8px | Inline gaps, icon spacing |
| space-3 | 12px | Tight component padding |
| space-4 | 16px | Default component gaps |
| space-5 | 24px | Card content padding |
| space-6 | 32px | Card padding, form spacing |
| space-8 | 48px | Section gaps |
| space-10 | 64px | Inter-section spacing |
| space-12 | 80px | Major section breaks |
| space-16 | 120px | Page section divisions, hero padding |
| space-20 | 160px | Hero vertical padding |

### Grid

- 12-column fluid grid
- Gutter: 16px (mobile), 24px (tablet), 40px (desktop)
- Max container: 1440px (content), full-bleed for hero sections
- Asymmetric layouts encouraged — 5/7, 4/8, or offset columns for visual interest

### Breakpoints

| Name | Width | Columns | Gutter |
|------|-------|---------|--------|
| Mobile | 0–767px | 4 | 16px |
| Tablet | 768–1023px | 8 | 24px |
| Desktop | 1024–1439px | 12 | 40px |
| Wide | 1440px+ | 12 | 40px |

### Whitespace Philosophy

Whitespace is a design element. Generous space around large type and hero content creates drama and draws the eye. Use visual weight contrast — dense information areas next to open breathing room — to create rhythm down the page.

### Border Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| radius-none | 0px | Editorial image crops, geometric accents |
| radius-sm | 8px | Small badges, tags |
| radius-md | 12px | Inputs, small cards |
| radius-lg | 16px | Cards, containers, sections |
| radius-xl | 24px | Feature cards, testimonial blocks |
| radius-pill | 999px | Buttons, search bars, nav pills |

## 6. Depth & Elevation

| Level | Name | Shadow Value (Dark) | Shadow Value (Light) | Usage |
|-------|------|--------------------|--------------------|-------|
| 0 | Flat | `none` | `none` | Default state, inline |
| 1 | Raised | `0 2px 8px rgba(0, 0, 0, 0.3)` | `0 2px 8px rgba(0, 0, 0, 0.06)` | Cards at rest |
| 2 | Elevated | `0 8px 32px rgba(0, 0, 0, 0.4)` | `0 8px 32px rgba(0, 0, 0, 0.1)` | Hover cards, dropdowns |
| 3 | Overlay | `0 16px 48px rgba(0, 0, 0, 0.5)` | `0 16px 48px rgba(0, 0, 0, 0.15)` | Modals, overlays |
| Glow | Primary | `0 8px 32px rgba(124, 58, 237, 0.3)` | `0 8px 32px rgba(124, 58, 237, 0.2)` | CTAs, primary emphasis |
| Glow | Accent | `0 8px 32px rgba(236, 72, 153, 0.25)` | `0 8px 32px rgba(236, 72, 153, 0.15)` | Accent emphasis |

**Elevation principles:**
- Colour shadows are a defining feature — use them on primary elements to extend the gradient palette into the space around the element
- Physical shadows (dark/neutral) are for structural elements; coloured glows are for interactive and hero elements
- Elevation changes should always animate (300ms ease) — never snap
- On dark backgrounds, shadows are less visible so pair them with subtle border or background shifts

## 7. Do's and Don'ts

### Do's

1. **Do** use the gradient generously — on buttons, text fills, section backgrounds, decorative elements
2. **Do** break the grid intentionally for hero sections, testimonial layouts, and feature showcases
3. **Do** animate on scroll — fade-ins, slide-ups, and scale reveals give the system its energy
4. **Do** use dramatic size contrast in typography (80px heading next to 14px overline)
5. **Do** let full-bleed colour sections interrupt the page rhythm to create visual chapters
6. **Do** use pill-shaped (999px radius) buttons for all primary CTAs
7. **Do** pair dark sections with light sections to create page rhythm and prevent monotony

### Don'ts

1. **Don't** use the gradient on body text — only headings, buttons, and decorative accents
2. **Don't** create dense, information-heavy layouts — this system breathes
3. **Don't** use thin, light font weights below 400 — the system demands presence
4. **Don't** skip hover animations on interactive elements — motion is expected
5. **Don't** use flat, unshadowed buttons for primary actions — the glow is part of the identity
6. **Don't** mix more than three colours from the palette in a single component
7. **Don't** use generic stock photography — the design quality demands art-directed imagery or abstract shapes

## 8. Responsive Behaviour

### Breakpoint Behaviour

| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 768px) | Single column. Display type scales to 40–48px. Hero padding reduces to 80px vertical. Card grid stacks. Navigation becomes full-screen overlay. Gradient sections become full-width bands. |
| Tablet (768–1023px) | Two-column layouts where appropriate. Display type at 48–56px. Asymmetric layouts become centred. |
| Desktop (1024–1439px) | Full layout with asymmetric grids. All navigation visible. Scroll animations active. |
| Wide (1440px+) | Content caps at 1440px. Full-bleed sections continue edge-to-edge. |

### Touch Targets

- Minimum: 48px × 48px (larger than standard — matches the bold aesthetic)
- CTA buttons: 52px minimum height on mobile
- Card tap targets: entire card surface is tappable

### Mobile-Specific Rules

- Reduce Display XL (80px) to 40px on mobile, maintaining visual weight via bold weight
- Scroll-triggered animations simplify to basic fade-in (preserve battery, reduce motion)
- Gradient backgrounds may simplify to solid primary colour for performance
- Full-screen mobile navigation with large type (32px links) and gradient accent
- Honour `prefers-reduced-motion` — disable all transforms, keep opacity fades only

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#7c3aed` | Primary purple |
| `--color-primary-light` | `#a78bfa` | Light purple, hover states |
| `--color-accent` | `#ec4899` | Pink accent |
| `--color-accent-light` | `#f472b6` | Light pink, hover |
| `--color-gradient` | `linear-gradient(135deg, #7c3aed, #ec4899)` | Signature gradient |
| `--color-bg-dark` | `#0f0f0f` | Dark mode background |
| `--color-bg-light` | `#ffffff` | Light mode background |
| `--color-surface-dark` | `#18181b` | Dark mode cards |
| `--color-surface-light` | `#fafafa` | Light mode cards |
| `--color-text-dark` | `#f8fafc` | Dark mode text |
| `--color-text-light` | `#0f0f0f` | Light mode text |
| `--color-text-secondary` | `#a1a1aa` | Secondary text (dark) |
| `--color-border-dark` | `#27272a` | Dark mode borders |
| `--color-border-light` | `#e4e4e7` | Light mode borders |
| `--color-success` | `#34d399` | Success states |
| `--color-error` | `#f87171` | Error states |
| `--font-display` | `'Space Grotesk', system-ui, sans-serif` | Headings |
| `--font-body` | `'Inter', system-ui, sans-serif` | Body text |
| `--radius-card` | `16px` | Card/container radius |
| `--radius-pill` | `999px` | Button radius |

### Ready-to-Use Prompts

**Prompt 1 — Hero section:**
> Build a hero section using the Agency Creative design system on dark background #0f0f0f. Headline in Space Grotesk 80px/700 with gradient text fill (linear-gradient 135deg #7c3aed to #ec4899 with background-clip text). 13px uppercase overline in #a1a1aa with 0.12em letter-spacing above the headline. Body text 18px Inter #a1a1aa, max 560px. Two buttons: primary pill with gradient background and 0 8px 32px rgba(124,58,237,0.3) glow, secondary pill with 2px #7c3aed border.

**Prompt 2 — Portfolio grid:**
> Create a portfolio case study grid on #0f0f0f. Cards with 16px radius on #18181b with 1px #27272a border. Card image takes full width with 0px top radius bleed. Below: 13px overline in uppercase #a1a1aa, 28px Space Grotesk 600 title in #f8fafc, 14px Inter description in #a1a1aa. Cards lift 4px on hover with 300ms spring easing and gain 0 12px 40px rgba(0,0,0,0.3) shadow. 3-column desktop, 2-column tablet, 1-column mobile.

**Prompt 3 — Services section (light mode):**
> Design a services section on #ffffff background. Section title: 48px Space Grotesk 700 #0f0f0f with gradient text fill on the emphasised word. Feature cards on #fafafa with 16px radius and 1px #e4e4e7 border. Each card: 48px gradient icon area, 22px Space Grotesk title, 16px Inter description in #52525b. Cards hover with 0 12px 40px rgba(0,0,0,0.08) shadow and -4px translateY.

**Prompt 4 — Contact/CTA section:**
> Build a full-width CTA section with gradient background (135deg #7c3aed to #ec4899). Display text 64px Space Grotesk 700 #ffffff centred. Subtext 18px Inter 400 rgba(255,255,255,0.85). White pill button: #ffffff background, #7c3aed text, 15px/600. On hover: translateY(-2px) with 0 8px 24px rgba(0,0,0,0.2) shadow. Vertical padding 120px.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
