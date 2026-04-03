# Design System: Agency Feminine

## 1. Visual Theme & Atmosphere

Agency Feminine is a soft, elegant design system built for brands that communicate through warmth, refinement, and understated beauty. It draws from editorial fashion, boutique hospitality, and curated lifestyle aesthetics — spaces where texture and tone matter more than volume. Every element is designed to feel intentional, considered, and quietly luxurious.

The palette is rooted in warm neutrals — cream backgrounds, dusty rose accents, and sage green counterpoints that evoke natural materials and handcrafted quality. Colour is never loud; it suggests rather than shouts. Typography pairs delicate serif headings (Cormorant, with its beautiful italic forms) with a clean, friendly sans-serif body (Lato), creating a hierarchy that feels both elevated and approachable.

Surfaces are soft with generous border-radius (12px standard), thin borders, and diffuse shadows that create gentle depth without harsh edges. Whitespace is luxurious — sections breathe, content floats, and the eye is guided rather than directed. Motion, where used, is slow and graceful: gentle fades, smooth reveals, nothing jarring.

**Key characteristics:**
- **Mood:** Warm, elegant, refined, nurturing, curated
- **Background:** Cream `#fdf6ee` — warm, never stark white
- **Signature colours:** Dusty rose `#d4a5a5`, sage green `#9caf88`
- **Typography feel:** Serif headings with italic flourishes, clean sans body
- **Corner treatment:** Soft and rounded — 12px default, 16px containers
- **Border style:** Thin (1px), subtle, warm-toned `#e8ddd0`
- **Shadow approach:** Diffuse, warm-toned, gentle depth
- **Density:** Low — generous padding, ample line-height, breathing room
- **Motion:** Gentle — 400–600ms ease-in-out, fade and slide, never bounce

## 2. Colour Palette & Roles

### Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#d4a5a5` | CTAs, active accents, key links |
| Primary Hover | `#c79393` | Darker rose for hover states |
| Primary Light | `#e8cece` | Soft backgrounds, badges, tag fills |
| Primary Muted | `#f5ebe7` | Tinted section backgrounds |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Accent | `#9caf88` | Secondary actions, tags, nature/wellness cues |
| Accent Hover | `#8a9d76` | Darker sage for hover |
| Accent Light | `#c5d4b8` | Soft accent backgrounds |
| Tertiary | `#c8a87e` | Gold/honey — sparingly for premium callouts |

### Text

| Role | Hex | Usage |
|------|-----|-------|
| Text Primary | `#3d3530` | Headings, body — warm near-black |
| Text Secondary | `#7a6e65` | Descriptions, captions |
| Text Tertiary | `#b0a59c` | Placeholders, disabled text, timestamps |
| Text Inverse | `#fdf6ee` | Text on dark/coloured backgrounds |
| Text Link | `#b07878` | Link colour, rose-toned |

### Surface

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#fdf6ee` | Page background, warm cream |
| Surface 1 | `#ffffff` | Cards, elevated content areas |
| Surface 2 | `#f8f0e5` | Alternating sections, subtle differentiation |
| Surface 3 | `#f0e6d8` | Active states, hover backgrounds |
| Border Default | `#e8ddd0` | Card borders, dividers |
| Border Subtle | `#f0e6d8` | Inner dividers, delicate separators |
| Border Focus | `#d4a5a5` | Focus rings, active borders |

### Semantic

| Role | Hex | Usage |
|------|-----|-------|
| Success | `#9caf88` | Confirmations, completed states (uses accent) |
| Success Background | `#f0f5ec` | Success message backgrounds |
| Warning | `#d4a56a` | Gentle warnings, attention needed |
| Warning Background | `#faf3e8` | Warning message backgrounds |
| Error | `#c97070` | Errors, required fields (softened red) |
| Error Background | `#faf0f0` | Error message backgrounds |
| Info | `#8aacc8` | Informational, help text (soft blue) |
| Info Background | `#f0f5fa` | Info message backgrounds |

### Shadows

| Role | Value | Usage |
|------|-------|-------|
| Soft | `0 2px 12px rgba(61, 53, 48, 0.06)` | Cards, slight lift |
| Medium | `0 4px 24px rgba(61, 53, 48, 0.08)` | Hover cards, dropdowns |
| Warm Glow | `0 0 20px rgba(212, 165, 165, 0.15)` | Primary element emphasis |

## 3. Typography Rules

### Font Families

| Role | Stack |
|------|-------|
| Serif | `'Cormorant Garamond', 'Cormorant', 'Playfair Display', Georgia, serif` |
| Sans | `'Lato', 'Source Sans 3', -apple-system, BlinkMacSystemFont, sans-serif` |

### Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Serif | 56px | 400 | 1.1 | -0.01em | Hero statements — use italic for elegance |
| H1 | Serif | 44px | 400 | 1.15 | -0.005em | Page titles |
| H2 | Serif | 36px | 400 | 1.2 | 0 | Section headings |
| H3 | Serif | 28px | 500 | 1.25 | 0 | Subsection headings |
| H4 | Serif | 22px | 500 | 1.3 | 0 | Card titles, group labels |
| H5 | Sans | 16px | 600 | 1.4 | 0.06em | Overlines, category labels (UPPERCASE) |
| Body Large | Sans | 18px | 300 | 1.8 | 0.005em | Lead paragraphs, introductions |
| Body | Sans | 16px | 300 | 1.75 | 0.005em | Primary reading text |
| Body Small | Sans | 14px | 400 | 1.6 | 0.005em | Captions, secondary info |
| Label | Sans | 12px | 400 | 1.4 | 0.05em | Form labels, metadata |
| Quote | Serif Italic | 24px | 400 italic | 1.5 | 0 | Testimonials, pull quotes |

### Typography Principles

- Serif (Cormorant) for all headings and display text — its light weights convey elegance
- Use italic Cormorant for testimonials, pull quotes, and hero emphasis
- Sans (Lato) at light weight (300) for body text creates an airy, approachable feel
- Body line-height is generous (1.75–1.8) to create breathing room in content
- Never use bold (700+) for serif headings — regular (400) or medium (500) only
- Uppercase is reserved for small labels and overlines, never headings

## 4. Component Stylings

### Buttons

**Primary Button**

```css
background: #d4a5a5
color: #ffffff
font: 14px/1 Lato, 500
padding: 14px 32px
border: none
border-radius: 999px
letter-spacing: 0.04em
transition: all 400ms ease-in-out

:hover    → background: #c79393; box-shadow: 0 4px 16px rgba(212, 165, 165, 0.25)
:active   → background: #b88282; transform: scale(0.98)
:focus    → outline: 2px solid #d4a5a5; outline-offset: 3px
:disabled → background: #e8cece; color: #b0a59c; cursor: not-allowed
```

**Secondary Button**

```css
background: transparent
color: #3d3530
font: 14px/1 Lato, 500
padding: 14px 32px
border: 1.5px solid #d4a5a5
border-radius: 999px
letter-spacing: 0.04em

:hover    → background: #f5ebe7; border-color: #c79393
:active   → background: #f0e6d8
:focus    → outline: 2px solid #d4a5a5; outline-offset: 3px
:disabled → color: #b0a59c; border-color: #e8ddd0
```

**Ghost Button**

```css
background: transparent
color: #7a6e65
font: 14px/1 Lato, 400
padding: 14px 32px
border: none
border-radius: 999px

:hover    → color: #3d3530; background: rgba(212, 165, 165, 0.08)
:active   → background: rgba(212, 165, 165, 0.12)
```

### Inputs

```css
background: #ffffff
color: #3d3530
font: 15px Lato, 300
padding: 14px 18px
border: 1px solid #e8ddd0
border-radius: 12px
transition: all 300ms ease

::placeholder → color: #b0a59c
:hover        → border-color: #d4ccc3
:focus        → border-color: #d4a5a5; box-shadow: 0 0 0 4px rgba(212, 165, 165, 0.12)
:invalid      → border-color: #c97070
:disabled     → background: #f8f0e5; color: #b0a59c
```

### Links

```css
color: #b07878
text-decoration: none
font-weight: 400
transition: color 300ms ease

:hover  → color: #966060; text-decoration: underline; text-underline-offset: 4px
:active → color: #7a4a4a
```

### Cards

```css
background: #ffffff
border: 1px solid #e8ddd0
border-radius: 16px
padding: 32px
box-shadow: 0 2px 12px rgba(61, 53, 48, 0.06)
transition: all 400ms ease-in-out

:hover → box-shadow: 0 4px 24px rgba(61, 53, 48, 0.08); transform: translateY(-2px)
```

### Navigation

```css
Background: #fdf6ee (or transparent with blur on scroll: backdrop-filter: blur(12px))
Height: 72px
Border bottom: 1px solid #e8ddd0
Logo: Cormorant serif wordmark, 24px, #3d3530
Nav items: 14px Lato, 400, #7a6e65
Active item: #3d3530, font-weight: 500
Hover item: #3d3530
CTA in nav: small pill button with #d4a5a5 background
```

## 5. Layout Principles

### Spacing Scale (8px base unit)

| Token | Value | Usage |
|-------|-------|-------|
| space-1 | 4px | Micro adjustments |
| space-2 | 8px | Inline gaps, icon spacing |
| space-3 | 12px | Tight component padding |
| space-4 | 16px | Default component gaps |
| space-5 | 24px | Content gaps within cards |
| space-6 | 32px | Card padding, form group spacing |
| space-8 | 48px | Section gaps |
| space-10 | 64px | Inter-section spacing |
| space-12 | 80px | Major section breaks |
| space-16 | 120px | Hero section padding |

### Grid

- 12-column grid
- Gutter: 16px (mobile), 24px (tablet), 32px (desktop)
- Max container: 1200px — narrower than typical for a more intimate, editorial feel
- Centre-weighted layouts preferred — content clusters toward the middle

### Breakpoints

| Name | Width | Columns | Gutter |
|------|-------|---------|--------|
| Mobile | 0–767px | 4 | 16px |
| Tablet | 768–1023px | 8 | 24px |
| Desktop | 1024–1199px | 12 | 32px |
| Wide | 1200px+ | 12 | 32px |

### Whitespace Philosophy

Space is elegance. Generous margins, ample padding, and open sections give content room to be appreciated. The design should feel like a beautifully typeset magazine — content is curated, not crammed. When in doubt, add more space.

### Border Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| radius-sm | 8px | Small badges, tags, inputs |
| radius-md | 12px | Buttons (non-pill), inputs, tooltips |
| radius-lg | 16px | Cards, containers |
| radius-xl | 24px | Feature sections, image frames |
| radius-pill | 999px | CTA buttons, search bars |

## 6. Depth & Elevation

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

## 7. Do's and Don'ts

### Do's

1. **Do** use Cormorant italic for testimonials, quotes, and hero emphasis — it's the system's signature flourish
2. **Do** maintain generous whitespace — every section should feel like it has room to breathe
3. **Do** use warm, natural photography: soft focus, natural light, organic textures
4. **Do** keep the colour palette restrained — dusty rose and sage with neutral cream, no more
5. **Do** use thin (1px–1.5px) borders — heavier borders feel out of place
6. **Do** use pill-shaped buttons for primary CTAs and rounded rectangles for secondary/form elements
7. **Do** test body text readability — light weights (300) on cream backgrounds need careful contrast checking

### Don'ts

1. **Don't** use bold/black font weights on serif headings — the elegance is in lightness
2. **Don't** use saturated, electric colours — all colour should feel dusty, muted, natural
3. **Don't** use sharp corners (< 8px radius) — the system is soft by nature
4. **Don't** use dark/black backgrounds — the warmth of cream is foundational (dark accents in small doses only)
5. **Don't** use mechanical, geometric imagery — opt for organic, flowing, and human
6. **Don't** overcrowd layouts with too many elements — curation is editing
7. **Don't** use aggressive hover animations (bounce, overshoot) — movement should feel like a gentle breath

## 8. Responsive Behaviour

### Breakpoint Behaviour

| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 768px) | Single column. Display type scales to 36px serif. Navigation collapses to hamburger with slide-in drawer. Cards stack full-width with reduced padding (24px). Images become full-bleed. |
| Tablet (768–1023px) | Two-column layouts. Display type at 44px. Cards in 2-up grid. Navigation visible or collapsed based on item count. |
| Desktop (1024–1199px) | Full layout. 3-column card grids. All navigation visible. Generous padding and margins. |
| Wide (1200px+) | Content maxes at 1200px container. Extra space is margin. |

### Touch Targets

- Minimum: 48px × 48px tap area
- CTA buttons: 52px minimum height on mobile
- Spacing between tappable elements: 12px minimum
- Form inputs: 52px height on mobile to prevent zoom

### Mobile-Specific Rules

- Serif display type minimum 28px on smallest screens to maintain readability
- Body text increases to 17px on mobile for comfortable reading
- Card padding reduces from 32px to 24px
- Section padding reduces from 120px to 64px vertical
- Pill buttons span full width on mobile for easy tapping
- Image galleries become horizontal scrollers rather than grids
- Honour `prefers-reduced-motion` — disable transforms, keep opacity transitions

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#d4a5a5` | Dusty rose — primary accent |
| `--color-primary-hover` | `#c79393` | Darker rose — hover |
| `--color-primary-light` | `#e8cece` | Light rose — backgrounds |
| `--color-accent` | `#9caf88` | Sage green — secondary |
| `--color-accent-hover` | `#8a9d76` | Darker sage — hover |
| `--color-bg` | `#fdf6ee` | Cream page background |
| `--color-surface` | `#ffffff` | Card/elevated surface |
| `--color-surface-alt` | `#f8f0e5` | Alternate section background |
| `--color-text` | `#3d3530` | Primary text (warm dark) |
| `--color-text-secondary` | `#7a6e65` | Secondary text |
| `--color-text-tertiary` | `#b0a59c` | Tertiary/placeholder |
| `--color-border` | `#e8ddd0` | Default border |
| `--color-success` | `#9caf88` | Success (sage green) |
| `--color-warning` | `#d4a56a` | Warning (warm amber) |
| `--color-error` | `#c97070` | Error (soft red) |
| `--font-serif` | `'Cormorant Garamond', Georgia, serif` | Headings |
| `--font-sans` | `'Lato', system-ui, sans-serif` | Body text |
| `--radius-default` | `12px` | Standard radius |
| `--radius-card` | `16px` | Card radius |
| `--radius-pill` | `999px` | Button radius |

### Ready-to-Use Prompts

**Prompt 1 — Landing hero:**
> Build a hero section on cream (#fdf6ee) background. Centred layout, max-width 720px. Overline: 12px Lato 400 uppercase #b0a59c with 0.06em tracking. Headline: 56px Cormorant Garamond italic 400 #3d3530 with -0.01em tracking. Subtext: 18px Lato 300 #7a6e65 with 1.8 line-height. Two pill buttons below: primary #d4a5a5/#fff, secondary transparent with 1.5px #d4a5a5 border. 120px vertical padding.

**Prompt 2 — Services/offering cards:**
> Create a 3-column card grid on #fdf6ee. Cards: #ffffff, 16px radius, 1px #e8ddd0 border, 32px padding, 0 2px 12px rgba(61,53,48,0.06) shadow. Each card: decorative icon in #d4a5a5 at top, 22px Cormorant 500 title, 16px Lato 300 #7a6e65 description (1.75 line-height). Hover: translateY(-2px) with 0 4px 24px rgba(61,53,48,0.08) shadow. 400ms ease-in-out transition.

**Prompt 3 — Testimonial section:**
> Design a testimonial block on #f8f0e5 background. Centred, max-width 640px. Large decorative quotation mark in #d4a5a5 above. Quote text in Cormorant Garamond italic 24px #3d3530 with 1.5 line-height. Attribution below: 14px Lato 400 #7a6e65, name in #3d3530 weight 500. Subtle 1px #e8ddd0 separator between quote and attribution. 80px vertical padding.

**Prompt 4 — Contact form:**
> Build a contact form on #ffffff surface with 16px radius and 32px padding. Form labels: 12px Lato 400 #7a6e65 with 0.05em letter-spacing. Inputs: #ffffff background, 1px #e8ddd0 border, 12px radius, 15px Lato 300, 14px 18px padding. Focus: #d4a5a5 border with 0 0 0 4px rgba(212,165,165,0.12) glow. Textarea: 120px min-height. Submit: full-width pill button #d4a5a5/#fff, 14px Lato 500, 14px 32px padding.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
