<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Design System: Luxury Premium

## 1. Visual Theme & Atmosphere

Exclusivity, craftsmanship, quiet confidence. Serves luxury automotive, high-end real estate, premium hospitality, fine jewellery, couture fashion. Restraint over embellishment throughout.

Near-black backgrounds create a cinematic stage for photography. Palette: black, near-black, white, single champagne gold accent. Ultra-light serif headings at large scale; body text small and secondary to imagery. Density extremely low — blackspace dominates. Transitions slow and cinematic (400–600ms).

**Key characteristics:**
- **Mood:** Exclusive, cinematic, restrained, aspirational
- **Background:** Black `#000000` or near-black `#0a0a0a`
- **Accent colour:** Champagne gold `#c9a96e`
- **Text colour:** White `#FFFFFF` with `rgba(255,255,255,0.7)` for secondary
- **Border treatment:** 1px `rgba(255,255,255,0.1)` — barely visible
- **Animation:** Slow, cinematic — 400–600ms ease, fade-ins, parallax
- **Imagery style:** Full-bleed, art-directed, high-contrast, minimal post-processing
- **Overall density:** Very low — massive negative space, few elements per viewport

## 2. Colour Palette & Roles

### Core Dark

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#000000` | Primary page background |
| Surface | `#0a0a0a` | Card backgrounds, elevated sections |
| Surface Raised | `#111111` | Interactive cards, input backgrounds |
| Surface Accent | `#1a1a1a` | Navigation overlay, footer |
| Border | `rgba(255, 255, 255, 0.08)` | Subtle dividers |
| Border Strong | `rgba(255, 255, 255, 0.15)` | Active borders, hover states |

### Text

| Role | Value | Usage |
|------|-------|-------|
| Primary | `#FFFFFF` | Headings, primary labels |
| Body | `rgba(255, 255, 255, 0.75)` | Paragraph text |
| Secondary | `rgba(255, 255, 255, 0.5)` | Captions, metadata, navigation |
| Tertiary | `rgba(255, 255, 255, 0.3)` | Disabled, deemphasised |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Gold | `#c9a96e` | CTAs, highlights, key interactive elements |
| Gold Light | `#d4b87a` | Hover states |
| Gold Dark | `#b08d50` | Active/pressed states |
| Gold Subtle | `rgba(201, 169, 110, 0.1)` | Tinted backgrounds, selected states |

### Light Mode (optional alternate)

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FFFFFF` | Alternate light pages |
| Surface | `#F7F5F0` | Light mode surface |
| Text | `#0a0a0a` | Light mode headings |
| Body | `#333333` | Light mode body |
| Border | `#E8E4DF` | Light mode borders |

### Semantic

| Role | Dark Mode | Usage |
|------|-----------|-------|
| Success | `#4ade80` | Confirmations (muted, not vibrant) |
| Warning | `#fbbf24` | Caution indicators |
| Error | `#f87171` | Errors, destructive actions |
| Info | `#c9a96e` | Informational — uses gold accent |

## 3. Typography Rules

**Font families:**
- **Headings:** `"Cormorant Garamond", Garamond, "Times New Roman", "Noto Serif", serif`
- **Body:** `system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif`
- **Monospace:** `"SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace`

### Hierarchy

| Role | Font | Size | Weight | Line-Height | Letter-Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Serif | 80px / 5rem | 300 | 1.05 | 0.02em | Hero headlines, dramatic impact |
| H1 | Serif | 56px / 3.5rem | 300 | 1.1 | 0.015em | Page titles |
| H2 | Serif | 40px / 2.5rem | 300 | 1.15 | 0.01em | Section headers |
| H3 | Serif | 30px / 1.875rem | 400 | 1.2 | 0.01em | Subsection headers |
| H4 | Sans-serif | 14px / 0.875rem | 400 | 1.3 | 0.15em | Labels, categories (uppercase) |
| Body | Sans-serif | 15px / 0.9375rem | 300 | 1.7 | 0.02em | Primary text |
| Body Small | Sans-serif | 13px / 0.8125rem | 300 | 1.6 | 0.03em | Secondary text |
| Caption | Sans-serif | 11px / 0.6875rem | 400 | 1.4 | 0.1em | Metadata (uppercase) |
| Pull Quote | Serif | 36px / 2.25rem | 300 | 1.3 | 0.01em | Featured quotes, italicised |

**Principles:**
- Weight 300 (light) is the dominant weight — it defines the luxury aesthetic
- Headings are large in size but light in weight — imposing yet delicate
- Uppercase is used for small labels and navigation, with generous letter-spacing (0.1em+)
- Body text is intentionally smaller than web defaults (15px) — content is secondary to imagery
- Avoid weight 700+ unless for rare emphasis — heaviness contradicts the luxury feel

## 4. Component Stylings

### Buttons

**Primary Button:**

```css
background: #c9a96e
color: #000000
padding: 16px 48px
border: none
border-radius: 0px
font-family: system-ui, sans-serif
font-size: 12px
font-weight: 400
letter-spacing: 0.15em
text-transform: uppercase
cursor: pointer
transition: all 400ms ease

:hover    → background: #d4b87a
:active   → background: #b08d50
:focus    → outline: 1px solid #c9a96e; outline-offset: 4px
:disabled → background: #333333; color: #666666; cursor: not-allowed
```

**Secondary Button:**

```css
background: transparent
color: #FFFFFF
padding: 16px 48px
border: 1px solid rgba(255, 255, 255, 0.3)
border-radius: 0px
font-size: 12px
font-weight: 400
letter-spacing: 0.15em
text-transform: uppercase
transition: all 400ms ease

:hover    → border-color: #FFFFFF; color: #FFFFFF
:active   → background: rgba(255, 255, 255, 0.05)
:disabled → border-color: rgba(255, 255, 255, 0.1); color: rgba(255, 255, 255, 0.3)
```

**Ghost Button (text link):**

```css
background: transparent
color: #c9a96e
padding: 8px 0
border: none
font-size: 12px
font-weight: 400
letter-spacing: 0.15em
text-transform: uppercase
border-bottom: 1px solid rgba(201, 169, 110, 0.3)
transition: all 400ms ease

:hover    → border-bottom-color: #c9a96e
:active   → color: #b08d50
```

### Inputs

```css
background: #111111
border: 1px solid rgba(255, 255, 255, 0.1)
border-radius: 0px
padding: 14px 16px
font-family: system-ui, sans-serif
font-size: 14px
font-weight: 300
color: #FFFFFF
letter-spacing: 0.02em
transition: border-color 400ms ease

:hover       → border-color: rgba(255, 255, 255, 0.2)
:focus       → border-color: #c9a96e; box-shadow: none
:error       → border-color: #f87171
::placeholder → color: rgba(255, 255, 255, 0.3)
:disabled    → background: #0a0a0a; color: rgba(255, 255, 255, 0.2)
```

**Labels:** 11px, weight 400, uppercase, letter-spacing 0.1em, colour `rgba(255,255,255,0.5)`, margin-bottom 8px.

### Links

```css
color: #c9a96e
text-decoration: none
font-weight: 300
letter-spacing: 0.02em
transition: color 400ms ease

:hover  → color: #d4b87a
:active → color: #b08d50
```

Navigation links (uppercase):

```css
color: rgba(255, 255, 255, 0.5)
font-size: 12px
letter-spacing: 0.15em
text-transform: uppercase

:hover  → color: #FFFFFF
:active → color: #c9a96e
```

### Cards

```css
background: #0a0a0a
border: 1px solid rgba(255, 255, 255, 0.06)
border-radius: 0px
padding: 0
overflow: hidden
transition: all 600ms ease

Image section: full-width, aspect 3:4 or 16:9
Content section: padding 32px

Interactive cards:
:hover → border-color: rgba(255, 255, 255, 0.12); transform: translateY(-4px)
```

### Navigation

```css
Top bar:
  background: transparent (absolute positioned over hero)
  height: 80px
  padding: 0 48px
  transition: background 400ms ease

Scrolled state:
  background: rgba(0, 0, 0, 0.9)
  backdrop-filter: blur(12px)

Logo:
  font-family: "Cormorant Garamond", serif
  font-size: 28px
  font-weight: 300
  letter-spacing: 0.05em
  color: #FFFFFF

Nav links:
  font-size: 12px
  font-weight: 400
  letter-spacing: 0.15em
  text-transform: uppercase
  color: rgba(255, 255, 255, 0.6)
  :hover  → color: #FFFFFF
  :active → color: #c9a96e
```

## 5. Layout Principles

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
- Content often occupies only 50–60% of the viewport width

### Container Widths

| Breakpoint | Container | Behaviour |
|-----------|-----------|-----------|
| ≥1440px | 1400px | Centred, generous side margins |
| 1024–1439px | 100% | 64px side padding |
| 768–1023px | 100% | 48px side padding |
| <768px | 100% | 24px side padding |

### Whitespace Philosophy

Negative space is the primary design material. Sections: 80–160px blackspace separation. Content in narrow columns; content-to-space ratio 30:70 or 20:80. Spatial generosity distinguishes luxury from merely dark themes.

### Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-none` | 0px | Buttons, inputs, cards — the default |
| `--radius-sm` | 2px | Rare — small interactive elements only |
| `--radius-full` | 9999px | Avatars only (if used at all) |

Sharp edges throughout. Rounded corners are antithetical to the luxury aesthetic.

## 6. Depth & Elevation

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

## 7. Do's and Don'ts

### Do's

1. **Do** use massive negative space — content should occupy less than half the viewport on desktop
2. **Do** keep headings at weight 300 (light) for the refined, luxury feel
3. **Do** use full-bleed, high-quality photography as the primary storytelling device
4. **Do** animate slowly and smoothly — 400–600ms transitions, ease timing
5. **Do** use uppercase sparingly and with generous letter-spacing (0.1em+) for labels and nav
6. **Do** maintain sharp corners (0px radius) on all rectangular elements
7. **Do** use the gold accent only for primary interactive elements — never decoratively
8. **Do** test all text against dark backgrounds for WCAG contrast compliance

### Don'ts

1. **Don't** use rounded corners — they undermine the precision aesthetic
2. **Don't** use bright, saturated colours — the palette is muted and restrained
3. **Don't** add multiple accent colours — champagne gold is the sole accent
4. **Don't** use fast animations (<200ms) — they feel cheap and nervous
5. **Don't** use heavy font weights (600+) for headings — weight 300 defines this system
6. **Don't** clutter the viewport — remove any element that does not serve a clear purpose
7. **Don't** use stock photography, clip art, or illustrations — only art-directed imagery
8. **Don't** use visible focus outlines thicker than 1px — subtlety extends to accessibility indicators
9. **Don't** place body text below 13px — legibility on dark backgrounds requires adequate size
10. **Don't** use emoji, playful icons, or informal language — tone is always elevated

## 8. Responsive Behaviour

### Breakpoints

| Name | Range | Columns | Gutter | Container Padding |
|------|-------|---------|--------|-------------------|
| Mobile | 0–767px | 4 | 16px | 24px |
| Tablet | 768–1023px | 8 | 24px | 48px |
| Desktop | 1024–1439px | 12 | 32px | 64px |
| Wide | ≥1440px | 12 | 32px | auto (centred 1400px) |

### Touch Targets

- Minimum tap target: 48×48px
- Navigation links: generous vertical padding (16px minimum)
- Buttons: full-width on mobile with 16px vertical padding

### Mobile-Specific Rules

- Navigation: full-screen overlay with centred vertical link stack, large text (20px)
- Hero images: full viewport height maintained; text overlay adjusts
- Typography: Display → 40px, H1 → 32px, H2 → 28px, Body remains 15px
- Grid: single column on mobile; asymmetric layouts collapse to stacked
- Spacing reduces proportionally: 160px → 80px, 80px → 48px, 48px → 32px
- Gallery: single-column vertical scroll, full-width images
- Video backgrounds: replaced with static key-frame image on mobile
- Navigation overlay: `background: rgba(0, 0, 0, 0.95)` with centred vertical text menu
- Horizontal scrolling: only for curated image galleries with snap scrolling
- Gold accent elements remain visible — do not hide or mute on mobile

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex / Value | Role |
|-------------|-------------|------|
| `--color-bg` | `#000000` | Black background |
| `--color-surface` | `#0a0a0a` | Near-black surface |
| `--color-surface-raised` | `#111111` | Interactive surfaces |
| `--color-surface-accent` | `#1a1a1a` | Nav overlay, footer |
| `--color-text` | `#FFFFFF` | Primary text (headings) |
| `--color-text-body` | `rgba(255,255,255,0.75)` | Body text |
| `--color-text-secondary` | `rgba(255,255,255,0.5)` | Captions, nav links |
| `--color-text-tertiary` | `rgba(255,255,255,0.3)` | Disabled, deemphasised |
| `--color-accent` | `#c9a96e` | Champagne gold — CTAs, highlights |
| `--color-accent-light` | `#d4b87a` | Gold hover |
| `--color-accent-dark` | `#b08d50` | Gold active |
| `--color-border` | `rgba(255,255,255,0.08)` | Subtle borders |
| `--color-border-strong` | `rgba(255,255,255,0.15)` | Active borders |

### Ready-to-Use Prompts

**Prompt 1 — Luxury brand landing page:**
> Build a landing page following DESIGN.md. Full-screen hero with a background image (100vh), transparent navigation (80px) with Cormorant Garamond logo (28px/300) and uppercase nav links (12px, letter-spacing 0.15em, rgba(255,255,255,0.6)). Hero headline in Cormorant Garamond 80px/300 white, centred. Below: full-bleed image section. Then a split layout (5/7 grid) with text on left (40px/300 serif heading, 15px/300/1.7 body in rgba(255,255,255,0.75)) and image on right. CTA button: gold (#c9a96e) background, black text, 0px radius, uppercase 12px with 0.15em letter-spacing. All backgrounds #000000. Section spacing: 120px+.

**Prompt 2 — Property/product showcase:**
> Create a showcase page following DESIGN.md. Full-bleed hero image (80vh) with a thin 1px rgba(255,255,255,0.08) border framing the content area. Title in Cormorant Garamond 56px/300 white. Specs section: 3-column grid on #0a0a0a with 1px border separators. Each spec: 11px uppercase label (rgba(255,255,255,0.5), 0.1em spacing) above 30px/300 serif value. Image gallery: two-column masonry grid with 4px gaps, images expand on click to a lightbox with 0 8px 32px rgba(0,0,0,0.4) shadow. Contact button: gold border, 0px radius, uppercase. Footer: #1a1a1a background.

**Prompt 3 — Booking/enquiry form:**
> Build an enquiry form following DESIGN.md. Centred at 480px max-width on #000000 background with 160px top padding. Heading in Cormorant Garamond 40px/300 white. Subtext in 15px/300 rgba(255,255,255,0.75). Inputs: #111111 background, 1px border rgba(255,255,255,0.1), 0px radius, 14px/300 white text. Labels: 11px uppercase, 0.1em letter-spacing, rgba(255,255,255,0.5). Focus state: border changes to #c9a96e, no shadow. Submit button: full-width, gold (#c9a96e) background, black text, 0px radius, uppercase. Privacy text below in 11px rgba(255,255,255,0.3). All transitions 400ms ease.

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
