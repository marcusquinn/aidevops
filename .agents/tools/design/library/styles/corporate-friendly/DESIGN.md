# Design System: Corporate Friendly

## 1. Visual Theme & Atmosphere

This design system balances professionalism with warmth and approachability. It serves organisations that need to feel trustworthy yet welcoming — healthcare portals, educational platforms, community-oriented SaaS, and customer-facing services where the user may feel uncertain or vulnerable. The design should reassure, not intimidate.

The colour palette leads with a calm, accessible blue and warms up with an energetic orange accent that signals optimism and action. Surfaces are predominantly light, with generous whitespace and rounded corners that soften every edge. Nothing feels sharp, clinical, or corporate-cold. The overall impression is one of quiet competence combined with genuine friendliness.

Typography uses a rounded, open sans-serif that reads clearly at all sizes and feels human rather than institutional. Spacing is deliberately generous — components breathe, sections are well-separated, and the interface never feels crowded. Subtle transitions and gentle shadows create a sense of depth without drama. The system is light-mode-first by design, reflecting the open and transparent character of the brands it serves.

**Key characteristics:**
- **Mood:** Warm, approachable, reassuring, professional
- **Primary colour:** Soft blue `#3b82f6`
- **Accent colour:** Warm orange `#f97316`
- **Background:** White `#FFFFFF` with warm grey sections `#F9FAFB`
- **Border treatment:** 1px solid `#E5E7EB`, rounded (12px default)
- **Animation:** Gentle — 200ms ease-in-out on colour, shadow, transform
- **Imagery style:** Warm photography, friendly illustrations, diverse representation
- **Overall density:** Low-medium — generous space prioritises comfort over density

## 2. Colour Palette & Roles

### Primary

| Role | Hex | Usage |
|------|-----|-------|
| Primary | `#3b82f6` | Primary buttons, active links, selected states |
| Primary Light | `#60a5fa` | Hover accents, progress indicators |
| Primary Dark | `#2563eb` | Active/pressed states |
| Primary Subtle | `#eff6ff` | Tinted backgrounds, info banners, selected rows |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Accent | `#f97316` | Secondary CTAs, highlights, badges, notifications |
| Accent Light | `#fb923c` | Hover on accent elements |
| Accent Dark | `#ea580c` | Active/pressed accent states |
| Accent Subtle | `#fff7ed` | Accent-tinted backgrounds, feature callouts |

### Text

| Role | Hex | Usage |
|------|-----|-------|
| Heading | `#111827` | All headings h1–h6 |
| Body | `#374151` | Paragraph text, descriptions |
| Secondary | `#6b7280` | Captions, helper text, metadata |
| Tertiary | `#9ca3af` | Placeholders, disabled text |
| Inverse | `#FFFFFF` | Text on dark/coloured backgrounds |

### Surface

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FFFFFF` | Primary page background |
| Surface | `#F9FAFB` | Alternate sections, sidebar, card backgrounds |
| Surface Warm | `#FFFBF5` | Testimonial sections, callout areas |
| Border | `#E5E7EB` | Default borders, dividers |
| Border Strong | `#D1D5DB` | Input focus borders, active separators |

### Semantic

| Role | Hex | Background | Usage |
|------|-----|-----------|-------|
| Success | `#16a34a` | `#f0fdf4` | Completion, positive feedback |
| Warning | `#eab308` | `#fefce8` | Caution, pending review |
| Error | `#ef4444` | `#fef2f2` | Validation errors, destructive actions |
| Info | `#3b82f6` | `#eff6ff` | Tips, informational messages |

## 3. Typography Rules

**Font families:**
- **All text:** `"DM Sans", system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
- **Monospace:** `"Fira Code", "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace`

### Hierarchy

| Role | Size | Weight | Line-Height | Letter-Spacing | Colour | Notes |
|------|------|--------|-------------|----------------|--------|-------|
| Display | 48px / 3rem | 700 | 1.15 | -0.02em | `#111827` | Landing page heroes |
| H1 | 36px / 2.25rem | 700 | 1.2 | -0.015em | `#111827` | Page titles |
| H2 | 28px / 1.75rem | 600 | 1.3 | -0.01em | `#111827` | Section headers |
| H3 | 22px / 1.375rem | 600 | 1.35 | -0.005em | `#111827` | Subsection headers |
| H4 | 18px / 1.125rem | 600 | 1.4 | 0 | `#111827` | Card titles |
| Body Large | 18px / 1.125rem | 400 | 1.65 | 0 | `#374151` | Introductory paragraphs |
| Body | 16px / 1rem | 400 | 1.65 | 0 | `#374151` | Default paragraph text |
| Body Small | 14px / 0.875rem | 400 | 1.55 | 0.005em | `#374151` | Secondary content |
| Caption | 12px / 0.75rem | 500 | 1.4 | 0.015em | `#6b7280` | Labels, timestamps |

**Principles:**
- Prefer weight 600 for headings (semibold) rather than 700 (bold) for a friendlier feel
- Line-height is generous (1.65 for body) to aid readability and reduce visual density
- Maximum content width: 720px for long-form reading
- Use optical alignment — visually align text to icons and other elements, not just mathematically

## 4. Component Stylings

### Buttons

**Primary Button:**
```
background: #3b82f6
color: #FFFFFF
padding: 12px 28px
border: none
border-radius: 12px
font-size: 15px
font-weight: 600
cursor: pointer
transition: all 200ms ease-in-out

:hover    → background: #2563eb; box-shadow: 0 4px 12px rgba(59, 130, 246, 0.3)
:active   → background: #1d4ed8; transform: translateY(1px)
:focus    → outline: 2px solid #3b82f6; outline-offset: 2px
:disabled → background: #D1D5DB; color: #9ca3af; cursor: not-allowed
```

**Secondary Button:**
```
background: #FFFFFF
color: #3b82f6
padding: 12px 28px
border: 1.5px solid #3b82f6
border-radius: 12px
font-size: 15px
font-weight: 600

:hover    → background: #eff6ff; border-color: #2563eb
:active   → background: #dbeafe
:disabled → border-color: #D1D5DB; color: #9ca3af
```

**Ghost Button:**
```
background: transparent
color: #3b82f6
padding: 12px 28px
border: none
border-radius: 12px
font-size: 15px
font-weight: 600

:hover    → background: #eff6ff
:active   → background: #dbeafe
```

**Accent Button (secondary CTA):**
```
background: #f97316
color: #FFFFFF
padding: 12px 28px
border-radius: 12px
font-size: 15px
font-weight: 600

:hover    → background: #ea580c; box-shadow: 0 4px 12px rgba(249, 115, 22, 0.3)
:active   → background: #c2410c; transform: translateY(1px)
```

### Inputs

```
background: #FFFFFF
border: 1.5px solid #E5E7EB
border-radius: 12px
padding: 12px 16px
font-size: 16px
color: #111827
transition: all 200ms ease-in-out

:hover       → border-color: #D1D5DB
:focus       → border-color: #3b82f6; box-shadow: 0 0 0 3px rgba(59, 130, 246, 0.15)
:error       → border-color: #ef4444; box-shadow: 0 0 0 3px rgba(239, 68, 68, 0.1)
::placeholder → color: #9ca3af
:disabled    → background: #F9FAFB; color: #9ca3af
```

**Labels:** 14px, weight 500, colour `#374151`, margin-bottom 8px.
**Helper text:** 13px, weight 400, colour `#6b7280`, margin-top 6px.
**Error messages:** 13px, weight 500, colour `#ef4444`, margin-top 6px.

### Links

```
color: #3b82f6
text-decoration: none
font-weight: 500
transition: color 200ms ease-in-out

:hover  → color: #2563eb; text-decoration: underline; text-underline-offset: 3px
:active → color: #1d4ed8
```

### Cards

```
background: #FFFFFF
border: 1px solid #E5E7EB
border-radius: 16px
padding: 28px
transition: all 200ms ease-in-out

Interactive cards:
:hover → border-color: #D1D5DB; box-shadow: 0 8px 24px rgba(0, 0, 0, 0.06); transform: translateY(-2px)
```

**Feature cards** (with icon): Add 48px icon container at top with `#eff6ff` background circle and `#3b82f6` icon.

### Navigation

```
Top bar:
  background: #FFFFFF
  border-bottom: 1px solid #E5E7EB
  height: 68px
  padding: 0 24px

Nav links:
  color: #6b7280
  font-size: 15px
  font-weight: 500
  border-radius: 8px
  padding: 8px 16px
  :hover  → color: #111827; background: #F9FAFB
  :active → color: #3b82f6; background: #eff6ff

Mobile nav:
  Full-width overlay, slide down from top
  background: #FFFFFF
  padding: 16px
```

## 5. Layout Principles

### Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline icon gaps |
| `--space-2` | 8px | Compact element spacing |
| `--space-3` | 12px | Input internal padding, tight groups |
| `--space-4` | 16px | Standard gap, list item spacing |
| `--space-5` | 24px | Card internal padding, form gaps |
| `--space-6` | 32px | Card padding, section internal spacing |
| `--space-7` | 48px | Section separation |
| `--space-8` | 64px | Major section breaks |
| `--space-9` | 80px | Hero padding, large breaks |
| `--space-10` | 120px | Page-level separation |

### Grid

- 12-column grid, 24px gutter
- Flex and CSS Grid for layout
- Common patterns: 2-column (50/50), 3-column (33/33/33), sidebar (30/70)
- Content never bleeds to viewport edge — minimum 20px padding always

### Container Widths

| Breakpoint | Container | Padding |
|-----------|-----------|---------|
| ≥1280px | 1200px | auto (centred) |
| 1024–1279px | 100% | 48px per side |
| 768–1023px | 100% | 32px per side |
| <768px | 100% | 20px per side |

### Whitespace Philosophy

Whitespace communicates care. Generous spacing between sections (48–80px) gives users breathing room and reduces cognitive load. Cards use 28–32px internal padding. Form fields are spaced 24px apart. The design should feel open and inviting — never cramped, never overwhelming.

### Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 6px | Tags, small badges |
| `--radius-md` | 12px | Buttons, inputs |
| `--radius-lg` | 16px | Cards, containers |
| `--radius-xl` | 20px | Feature sections, hero elements |
| `--radius-full` | 9999px | Avatars, pills, toggles |

## 6. Depth & Elevation

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Default state, borders handle separation |
| 1 | Raised | `0 1px 3px rgba(0, 0, 0, 0.04), 0 1px 2px rgba(0, 0, 0, 0.03)` | Cards at rest |
| 2 | Elevated | `0 8px 24px rgba(0, 0, 0, 0.06), 0 2px 6px rgba(0, 0, 0, 0.03)` | Hover cards, active components |
| 3 | Overlay | `0 12px 32px rgba(0, 0, 0, 0.08), 0 4px 12px rgba(0, 0, 0, 0.04)` | Dropdowns, popovers, tooltips |
| 4 | Modal | `0 24px 48px rgba(0, 0, 0, 0.12), 0 8px 24px rgba(0, 0, 0, 0.06)` | Modal dialogs |

**Elevation principles:**
- Shadows are always neutral black-based (`rgba(0,0,0,...)`) for warmth
- Cards hover upward with `transform: translateY(-2px)` paired with level 2 shadow
- Shadows increase gradually — no harsh jumps between levels
- Modal backdrop: `rgba(0, 0, 0, 0.3)` — lighter than typical, keeping the friendly feel

## 7. Do's and Don'ts

### Do's

1. **Do** use rounded corners consistently — 12px for small components, 16px for cards, 20px for major sections
2. **Do** pair blue with orange intentionally — blue for primary actions, orange for secondary emphasis
3. **Do** use warm, natural photography showing real people in positive contexts
4. **Do** maintain generous line-height (1.65) for body text to maximise readability
5. **Do** include helpful microcopy — tooltips, helper text, success messages
6. **Do** use the warm surface tones (`#FFFBF5`) for testimonial and trust sections
7. **Do** animate interactions gently — hover lifts, smooth colour transitions, subtle feedback
8. **Do** ensure at least 48px vertical space between distinct content sections

### Don'ts

1. **Don't** use sharp corners (0–4px radius) — they conflict with the friendly aesthetic
2. **Don't** combine blue and orange at equal visual weight — one should clearly dominate
3. **Don't** use dark mode as default — this system is light-mode-first for warmth
4. **Don't** pack content tightly — if a section feels dense, add more whitespace
5. **Don't** use aggressive micro-interactions (shake, bounce, pulse) for errors — gentle colour changes suffice
6. **Don't** place orange (`#f97316`) text on white backgrounds for body copy — insufficient contrast
7. **Don't** use stock photography that feels cold, staged, or corporate — prioritise warmth and authenticity
8. **Don't** hide critical navigation behind icons without labels — always include text labels on primary nav

## 8. Responsive Behaviour

### Breakpoints

| Name | Range | Columns | Gutter | Container Padding |
|------|-------|---------|--------|-------------------|
| Mobile | 0–767px | 4 | 16px | 20px |
| Tablet | 768–1023px | 8 | 24px | 32px |
| Desktop | 1024–1279px | 12 | 24px | 48px |
| Wide | ≥1280px | 12 | 24px | auto (centred 1200px) |

### Touch Targets

- Minimum tap target: 48×48px (larger than standard 44px for friendliness)
- Minimum gap between targets: 12px
- Mobile buttons: full-width below 480px
- Checkboxes and radio buttons: minimum 24×24px visible target

### Mobile-Specific Rules

- Top navigation becomes a hamburger menu or bottom tab bar at <768px
- Card grid becomes single-column stacked layout
- Cards maintain 20px padding on mobile (down from 28px)
- Typography: H1 → 28px, H2 → 24px, Body remains 16px
- Form fields stack vertically; inline field groups become full-width
- CTAs stick to bottom of viewport on key conversion pages
- Section padding reduces: 80px → 48px, 48px → 32px
- Image aspect ratios maintain; hero images may crop to 4:3 on mobile
- Floating tooltips become inline expandable help text

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-primary` | `#3b82f6` | Blue — buttons, links, active states |
| `--color-primary-light` | `#60a5fa` | Hover highlights |
| `--color-primary-dark` | `#2563eb` | Active/pressed |
| `--color-primary-subtle` | `#eff6ff` | Tinted backgrounds |
| `--color-accent` | `#f97316` | Orange — secondary CTAs, badges |
| `--color-accent-light` | `#fb923c` | Accent hover |
| `--color-accent-subtle` | `#fff7ed` | Accent backgrounds |
| `--color-text` | `#111827` | Headings |
| `--color-text-body` | `#374151` | Body text |
| `--color-text-secondary` | `#6b7280` | Captions, helpers |
| `--color-surface` | `#FFFFFF` | Page background |
| `--color-surface-alt` | `#F9FAFB` | Alternate sections |
| `--color-surface-warm` | `#FFFBF5` | Testimonial/trust sections |
| `--color-border` | `#E5E7EB` | Default borders |
| `--color-success` | `#16a34a` | Success states |
| `--color-warning` | `#eab308` | Warning states |
| `--color-error` | `#ef4444` | Error states |

### Ready-to-Use Prompts

**Prompt 1 — Healthcare/education landing page:**
> Build a landing page following DESIGN.md. White background with a 68px navbar (white, bottom border #E5E7EB). Hero with 36px/700 heading in #111827, 18px body in #374151, primary blue (#3b82f6) CTA with 12px radius, and a secondary orange (#f97316) button. Feature section on #F9FAFB with 3 cards (16px radius, #E5E7EB border) each with a blue icon in a circular #eff6ff container. Testimonial section on #FFFBF5 warm background with rounded cards and friendly avatar photos. All spacing follows the 8px grid with generous 64–80px section breaks.

**Prompt 2 — User onboarding flow:**
> Create a multi-step onboarding wizard following DESIGN.md. Centred container at 560px max-width on white background. Step indicator at top with blue (#3b82f6) filled circles for completed steps, outlined for upcoming. Each step has a friendly H2 (28px/600), descriptive body text (16px/1.65 line-height), and form inputs with 12px radius and 1.5px #E5E7EB borders that transition to blue on focus. Progress bar in #3b82f6. Primary "Continue" button full-width in blue, "Back" as ghost button. Generous 32px spacing between form fields.

**Prompt 3 — Patient/student portal dashboard:**
> Build a portal dashboard following DESIGN.md. Left sidebar (280px) on #F9FAFB with rounded (8px) nav items — active item has #eff6ff background and #3b82f6 text. Main area on white. Welcome message with the user's name in 28px/600. Stat cards in a 3-column grid (16px radius, 1px #E5E7EB border) with large metric numbers in #111827 and orange (#f97316) accent on important callouts. Upcoming appointments/tasks in a clean list with 16px spacing, blue dots for status, and friendly time formatting. Action buttons in blue, secondary actions in outlined style.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
