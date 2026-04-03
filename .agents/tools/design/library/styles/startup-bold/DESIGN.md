# Design System: Startup Bold

## 1. Visual Theme & Atmosphere

Startup Bold is an energetic, high-confidence design system built for products that need to capture attention fast and convert. It channels the urgency of launch-day energy, the optimism of well-funded startups, and the visual clarity of products that know exactly what they are. Colour is strong, type is big, and every element competes for the user's next click.

The palette centres on a rich indigo primary with an electric emerald accent — two colours that create natural visual hierarchy when used together. Backgrounds are clean whites with strategic use of soft tinted sections to break up content. Components are bold and rounded (12px radius standard), with solid colour fills rather than outlines or ghosts. The system favours high contrast and dense visual weight — lightweight elements feel out of place here.

Layout is structured and rhythmic. A clear grid with consistent spacing creates a sense of reliability, while large typography and bold CTAs create urgency. Whitespace is purposeful: enough to let elements breathe, never so much that the page feels empty. Motion is confident — elements arrive with purpose, not with flourish.

**Key characteristics:**
- **Mood:** Energetic, confident, optimistic, trustworthy, fast
- **Background:** Clean white `#ffffff` with soft surface tints
- **Signature colours:** Indigo `#4f46e5` (primary), Emerald `#10b981` (accent)
- **Typography feel:** Bold sans-serif, large headings, strong hierarchy
- **Corner treatment:** Rounded — 12px default, 16px for larger containers
- **Border style:** Minimal — solid colour and background shifts over borders
- **Shadow approach:** Clean neutral shadows, medium diffusion
- **Density:** Medium — structured and rhythmic, not cramped or sparse
- **Motion:** Confident — 200–300ms ease-out, purposeful entrance animations

## 2. Colour Palette & Roles

### Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#4f46e5` | CTAs, primary buttons, active navigation |
| Primary Hover | `#4338ca` | Hover state |
| Primary Dark | `#3730a3` | Active/pressed state |
| Primary Light | `#e0e7ff` | Badges, tinted backgrounds, selection highlights |
| Primary Ghost | `rgba(79, 70, 229, 0.06)` | Hover backgrounds for ghost elements |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Accent | `#10b981` | Secondary CTAs, success-adjacent actions, pricing highlights |
| Accent Hover | `#059669` | Hover state |
| Accent Dark | `#047857` | Active state |
| Accent Light | `#d1fae5` | Accent tinted backgrounds, badges |

### Text

| Role | Hex | Usage |
|------|-----|-------|
| Text Primary | `#111827` | Headings, primary body content |
| Text Secondary | `#6b7280` | Descriptions, captions, metadata |
| Text Tertiary | `#9ca3af` | Placeholders, disabled text |
| Text Inverse | `#ffffff` | Text on primary/dark backgrounds |
| Text Link | `#4f46e5` | Inline links |

### Surface

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#ffffff` | Page background |
| Surface 1 | `#f9fafb` | Alternating sections, card backgrounds |
| Surface 2 | `#f3f4f6` | Elevated backgrounds, input backgrounds |
| Surface 3 | `#e5e7eb` | Active states, pressed backgrounds |
| Border Default | `#e5e7eb` | Card borders, dividers |
| Border Subtle | `#f3f4f6` | Inner dividers, light separators |
| Border Focus | `#4f46e5` | Focus rings |

### Semantic

| Role | Hex | Usage |
|------|-----|-------|
| Success | `#10b981` | Confirmations, completed (shares accent) |
| Success Background | `#ecfdf5` | Success banners |
| Warning | `#f59e0b` | Caution, attention needed |
| Warning Background | `#fffbeb` | Warning banners |
| Error | `#ef4444` | Errors, destructive actions |
| Error Background | `#fef2f2` | Error banners |
| Info | `#3b82f6` | Informational, tips |
| Info Background | `#eff6ff` | Info banners |

### Shadows

| Role | Value | Usage |
|------|-------|-------|
| Subtle | `0 1px 3px rgba(0, 0, 0, 0.06)` | Slight lift, resting cards |
| Medium | `0 4px 16px rgba(0, 0, 0, 0.08)` | Hover cards, dropdowns |
| Strong | `0 8px 32px rgba(0, 0, 0, 0.1)` | Modals, popovers |
| Primary Glow | `0 4px 16px rgba(79, 70, 229, 0.25)` | Primary CTA emphasis |
| Accent Glow | `0 4px 16px rgba(16, 185, 129, 0.2)` | Accent CTA emphasis |

## 3. Typography Rules

### Font Families

| Role | Stack |
|------|-------|
| Sans | `'Plus Jakarta Sans', 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif` |
| Mono | `'JetBrains Mono', 'Fira Code', 'SF Mono', monospace` |

### Type Scale

| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Sans | 64px | 800 | 1.05 | -0.035em | Landing heroes, pricing headlines |
| H1 | Sans | 48px | 700 | 1.1 | -0.03em | Page titles |
| H2 | Sans | 36px | 700 | 1.15 | -0.025em | Section headings |
| H3 | Sans | 28px | 600 | 1.2 | -0.02em | Subsection headings |
| H4 | Sans | 22px | 600 | 1.25 | -0.01em | Card titles |
| H5 | Sans | 18px | 600 | 1.3 | -0.005em | Group labels, small headings |
| Overline | Sans | 13px | 600 | 1.4 | 0.06em | Category labels (UPPERCASE) |
| Body Large | Sans | 18px | 400 | 1.65 | -0.006em | Lead paragraphs |
| Body | Sans | 16px | 400 | 1.6 | -0.006em | Primary reading text |
| Body Small | Sans | 14px | 400 | 1.5 | 0 | Captions, secondary info |
| Label | Sans | 13px | 500 | 1.4 | 0.02em | Form labels, buttons, metadata |
| Code | Mono | 14px | 400 | 1.6 | 0 | Code snippets, technical content |

### Typography Principles

- Headings are heavy (700–800) to command attention — this is not a delicate system
- Negative letter-spacing on headings tightens the visual weight as size increases
- Body text at 400 weight provides clear contrast against bold headings
- Use uppercase overlines sparingly to categorise sections
- One typeface family (Plus Jakarta Sans) creates cohesion — variation comes from weight and size

## 4. Component Stylings

### Buttons

**Primary Button**

```css
background: #4f46e5
color: #ffffff
font: 14px/1 Plus Jakarta Sans, 600
padding: 12px 28px
border: none
border-radius: 12px
box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06)
transition: all 200ms ease-out

:hover    → background: #4338ca; box-shadow: 0 4px 16px rgba(79, 70, 229, 0.25); transform: translateY(-1px)
:active   → background: #3730a3; transform: translateY(0); box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06)
:focus    → outline: 2px solid #4f46e5; outline-offset: 2px
:disabled → background: #c7d2fe; cursor: not-allowed; transform: none
```

**Secondary Button**

```css
background: #ffffff
color: #4f46e5
font: 14px/1 Plus Jakarta Sans, 600
padding: 12px 28px
border: 2px solid #4f46e5
border-radius: 12px

:hover    → background: #e0e7ff; border-color: #4338ca
:active   → background: #c7d2fe
:focus    → outline: 2px solid #4f46e5; outline-offset: 2px
:disabled → color: #9ca3af; border-color: #e5e7eb
```

**Ghost Button**

```css
background: transparent
color: #6b7280
font: 14px/1 Plus Jakarta Sans, 500
padding: 12px 28px
border: none
border-radius: 12px

:hover    → color: #111827; background: rgba(79, 70, 229, 0.06)
:active   → background: rgba(79, 70, 229, 0.1)
```

**Accent Button (for secondary CTA — "Start Free", "Try Now")**

```css
background: #10b981
color: #ffffff
font: 14px/1 Plus Jakarta Sans, 600
padding: 12px 28px
border: none
border-radius: 12px

:hover    → background: #059669; box-shadow: 0 4px 16px rgba(16, 185, 129, 0.2)
:active   → background: #047857
```

### Inputs

```css
background: #f9fafb
color: #111827
font: 15px Plus Jakarta Sans
padding: 12px 16px
border: 1.5px solid #e5e7eb
border-radius: 12px
transition: all 200ms ease

::placeholder → color: #9ca3af
:hover        → border-color: #d1d5db
:focus        → border-color: #4f46e5; background: #ffffff; box-shadow: 0 0 0 4px rgba(79, 70, 229, 0.1)
:invalid      → border-color: #ef4444
:disabled     → background: #f3f4f6; color: #9ca3af
```

### Links

```css
color: #4f46e5
font-weight: 500
text-decoration: none
transition: color 200ms ease

:hover  → color: #4338ca; text-decoration: underline; text-underline-offset: 3px
:active → color: #3730a3
```

### Cards

```css
background: #ffffff
border: 1px solid #e5e7eb
border-radius: 16px
padding: 28px
box-shadow: 0 1px 3px rgba(0, 0, 0, 0.06)
transition: all 200ms ease-out

:hover → box-shadow: 0 4px 16px rgba(0, 0, 0, 0.08); transform: translateY(-2px)
```

### Navigation

```css
Background: #ffffff
Border bottom: 1px solid #e5e7eb
Height: 64px
Logo: Plus Jakarta Sans 700 wordmark, 20px, #111827
Nav items: 15px Plus Jakarta Sans, 500, #6b7280
Active item: #111827, font-weight: 600
Hover item: #111827
CTA in nav: small primary button with #4f46e5 background
```

## 5. Layout Principles

### Spacing Scale (4px base unit)

| Token | Value | Usage |
|-------|-------|-------|
| space-1 | 4px | Micro adjustments, icon padding |
| space-2 | 8px | Inline gaps, tight spacing |
| space-3 | 12px | Component internal padding |
| space-4 | 16px | Default component gaps |
| space-5 | 20px | Card content spacing |
| space-6 | 24px | Form group spacing |
| space-8 | 32px | Card padding, section sub-gaps |
| space-10 | 40px | Section gaps |
| space-12 | 48px | Inter-section spacing |
| space-16 | 64px | Major section breaks |
| space-20 | 80px | Hero section padding |
| space-24 | 96px | Page section divisions |

### Grid

- 12-column grid
- Gutter: 16px (mobile), 24px (tablet), 32px (desktop)
- Max container: 1280px, centered
- Content-width variant: 768px for article/text-heavy pages

### Breakpoints

| Name | Width | Columns | Gutter |
|------|-------|---------|--------|
| Mobile | 0–639px | 4 | 16px |
| Tablet | 640–1023px | 8 | 24px |
| Desktop | 1024–1279px | 12 | 32px |
| Wide | 1280px+ | 12 | 32px |

### Whitespace Philosophy

Space creates confidence. Consistent, rhythmic spacing communicates reliability and polish. Every spacing decision should reinforce the grid — no arbitrary values. Tight where elements are related, open where sections need separation.

### Border Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| radius-sm | 6px | Small badges, chips |
| radius-md | 12px | Buttons, inputs, default |
| radius-lg | 16px | Cards, containers |
| radius-xl | 24px | Feature cards, testimonial blocks |
| radius-full | 9999px | Avatars, status dots |

## 6. Depth & Elevation

| Level | Name | Shadow Value | Usage |
|-------|------|-------------|-------|
| 0 | Flat | `none` | Default state, elements on coloured backgrounds |
| 1 | Resting | `0 1px 3px rgba(0, 0, 0, 0.06)` | Cards at rest, nav bar |
| 2 | Raised | `0 4px 16px rgba(0, 0, 0, 0.08)` | Hover cards, dropdowns |
| 3 | Elevated | `0 8px 32px rgba(0, 0, 0, 0.1)` | Popovers, tooltips |
| 4 | Overlay | `0 16px 48px rgba(0, 0, 0, 0.12)` | Modals, full overlays |
| Glow | Primary | `0 4px 16px rgba(79, 70, 229, 0.25)` | Primary CTA hover emphasis |
| Glow | Accent | `0 4px 16px rgba(16, 185, 129, 0.2)` | Accent CTA hover emphasis |

**Elevation principles:**
- Resting state (level 1) gives all cards a subtle groundedness — nothing floats without context
- Hover reveals higher elevation (1 → 2) with smooth transition
- Coloured glow shadows are reserved for CTA buttons only — not cards or containers
- Modals get level 4 plus a semi-transparent overlay backdrop (`rgba(0,0,0,0.4)`)
- Shadow transitions should always animate (200ms ease-out)

## 7. Do's and Don'ts

### Do's

1. **Do** use bold font weights (600–800) for headings — confidence starts with type
2. **Do** use the indigo/emerald combination for clear primary/secondary action hierarchy
3. **Do** use solid-fill buttons for primary CTAs — outlines and ghosts are for secondary actions
4. **Do** alternate between white and `#f9fafb` section backgrounds to create visual rhythm
5. **Do** include social proof elements (metrics, logos, testimonials) near CTAs for conversion
6. **Do** maintain consistent 12px border-radius across all components for system cohesion
7. **Do** use the accent (emerald) for action-oriented CTAs: "Start Free", "Get Started", "Try Now"

### Don'ts

1. **Don't** use light font weights (300 or below) — they undermine the bold personality
2. **Don't** use more than two brand colours in a single section (indigo + emerald is the max)
3. **Don't** use decorative borders or patterns — the system is clean and structural
4. **Don't** mix rounded and sharp corners within the same component group
5. **Don't** use grey buttons for primary CTAs — reserve grey for truly tertiary actions
6. **Don't** crowd the above-the-fold area with competing CTAs — one primary, one secondary max
7. **Don't** use thin (1px) borders on buttons — either solid fill or 2px border for visibility

## 8. Responsive Behaviour

### Breakpoint Behaviour

| Breakpoint | Layout Changes |
|------------|---------------|
| Mobile (< 640px) | Single column. Display type scales to 36px. Hero CTAs stack vertically full-width. Card grid stacks. Navigation collapses to hamburger. Pricing cards stack. Logo grid becomes 2-up. |
| Tablet (640–1023px) | Two-column layouts. Display type at 48px. Card grid goes 2-up. Side-by-side hero layout stacks but images remain inline. |
| Desktop (1024–1279px) | Full layout. 3-column card grids. Pricing comparison side-by-side. All navigation visible. |
| Wide (1280px+) | Content maxes at 1280px. 4-column feature grids where applicable. |

### Touch Targets

- Minimum: 44px × 44px tap area
- CTA buttons: 48px minimum height on mobile
- Spacing between tappable elements: 8px minimum
- Form inputs: 48px height on mobile

### Mobile-Specific Rules

- Hero CTA buttons become full-width and stack vertically
- Card padding reduces from 28px to 20px
- Section vertical padding reduces by ~40% (96px → 56px)
- Body text stays at 16px — never reduce for mobile
- Sticky mobile CTA bar at bottom for key conversion pages
- Logo grids become horizontally scrollable carousels
- Honour `prefers-reduced-motion` — disable transforms, keep fade transitions

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#4f46e5` | Indigo — primary actions |
| `--color-primary-hover` | `#4338ca` | Primary hover |
| `--color-primary-light` | `#e0e7ff` | Primary tinted backgrounds |
| `--color-accent` | `#10b981` | Emerald — secondary CTA |
| `--color-accent-hover` | `#059669` | Accent hover |
| `--color-accent-light` | `#d1fae5` | Accent tinted backgrounds |
| `--color-bg` | `#ffffff` | Page background |
| `--color-surface-1` | `#f9fafb` | Alternating section bg |
| `--color-surface-2` | `#f3f4f6` | Input backgrounds |
| `--color-text` | `#111827` | Primary text |
| `--color-text-secondary` | `#6b7280` | Secondary text |
| `--color-text-tertiary` | `#9ca3af` | Placeholder text |
| `--color-border` | `#e5e7eb` | Default borders |
| `--color-success` | `#10b981` | Success |
| `--color-warning` | `#f59e0b` | Warning |
| `--color-error` | `#ef4444` | Error |
| `--font-sans` | `'Plus Jakarta Sans', 'Inter', sans-serif` | All text |
| `--font-mono` | `'JetBrains Mono', monospace` | Code |
| `--radius-default` | `12px` | Standard radius |
| `--radius-card` | `16px` | Card radius |

### Ready-to-Use Prompts

**Prompt 1 — SaaS landing hero:**
> Build a hero section on #ffffff. Left side: 13px uppercase overline #6b7280 with 0.06em tracking, 64px Plus Jakarta Sans 800 heading #111827 with -0.035em tracking, 18px body #6b7280 1.65 line-height (max 480px), two buttons — primary #4f46e5 pill 12px radius and secondary white with 2px #4f46e5 border. Right side: product screenshot in a card with 16px radius and 0 8px 32px rgba(0,0,0,0.1) shadow. Below hero: logo bar on #f9fafb — "Trusted by" in 13px #9ca3af, 5 greyscale logos.

**Prompt 2 — Pricing cards:**
> Create a 3-column pricing grid on #f9fafb section. Cards: #ffffff, 16px radius, 1px #e5e7eb border. Each: plan name 18px/600, price 48px/800 #111827, period 16px/400 #6b7280, feature list with #10b981 checkmarks. Middle card (recommended): 2px #4f46e5 border, "Most Popular" badge in #e0e7ff/#4f46e5 at top. CTA buttons: recommended card gets #4f46e5 primary fill, others get secondary outline. Hover: translateY(-2px) with medium shadow.

**Prompt 3 — Feature grid:**
> Design a 3-column feature grid on #ffffff. Section title: 36px Plus Jakarta Sans 700 #111827 centred, 16px subtitle #6b7280. Feature cards: no border, 28px padding. Each: 48px icon container with #e0e7ff background and #4f46e5 icon, 22px/600 title, 16px/400 #6b7280 description. Hover: background shifts to #f9fafb with 200ms ease-out. 32px gap between cards.

**Prompt 4 — CTA banner:**
> Build a full-width CTA section on #4f46e5 background. Centred content, max-width 640px. Heading: 36px Plus Jakarta Sans 700 #ffffff. Subtext: 16px #e0e7ff. Two buttons: white fill (#ffffff bg, #4f46e5 text) as primary, white outline (transparent bg, 2px #ffffff border, #ffffff text) as secondary. Both 12px radius. 80px vertical padding. Subtle pattern or gradient overlay optional.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
