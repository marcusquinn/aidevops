# Design System: Editorial Clean

## 1. Visual Theme & Atmosphere

This design system is built for reading. Every decision — colour, spacing, typography, layout — serves a single purpose: to make long-form content a pleasure to consume. It draws from the best traditions of print editorial design and modern digital reading platforms, where the content is the interface and the chrome dissolves into the background.

The palette is deliberately restrained: warm off-white paper tones, near-black ink colours, and minimal accent use. The warmth of the background (`#faf8f5`) avoids the clinical harshness of pure white, reducing eye strain during extended reading sessions. Colour is used almost exclusively for interactive elements — links, buttons, and navigation — never for decoration.

Typography is the star of this system. A refined serif for headings establishes editorial authority, while a clean humanist sans-serif for body text provides sustained readability across thousands of words. Line-height is generous (1.7), line length is capped at 680px, and paragraph spacing is carefully tuned to create a natural reading rhythm. The result should feel like opening a beautifully typeset book — inviting, effortless, and timeless.

**Key characteristics:**
- **Mood:** Calm, focused, literary, refined
- **Background:** Warm off-white `#FAF8F5`
- **Text colour:** Near-black `#1a1a1a`
- **Accent:** Muted blue `#4a6fa5`
- **Content width:** 680px maximum for body text
- **Border treatment:** Minimal — 1px `#E8E4DF` for separators only
- **Animation:** Almost none — instant state changes, no decorative motion
- **Imagery style:** Full-bleed photography, art-directed, no stock feel
- **Overall density:** Low — content breathes, generous margins throughout

## 2. Colour Palette & Roles

### Core

| Role | Hex | Usage |
|------|-----|-------|
| Background | `#FAF8F5` | Primary page background (paper tone) |
| Surface | `#FFFFFF` | Cards, overlays, input backgrounds |
| Surface Dark | `#F2EFE9` | Code blocks, pull quotes, alternate sections |
| Border | `#E8E4DF` | Dividers, section separators |
| Border Light | `#F0ECE6` | Subtle separators, nested dividers |

### Text

| Role | Hex | Usage |
|------|-----|-------|
| Heading | `#1a1a1a` | All headings |
| Body | `#2d2d2d` | Primary reading text |
| Secondary | `#666666` | Bylines, dates, captions, metadata |
| Tertiary | `#999999` | Footnotes, deemphasised text |
| Inverse | `#FAF8F5` | Text on dark backgrounds |

### Accent

| Role | Hex | Usage |
|------|-----|-------|
| Link | `#4a6fa5` | Inline links, navigation active state |
| Link Hover | `#364f75` | Hovered links |
| Link Visited | `#6b5b8a` | Visited links (optional) |
| Highlight | `#FFF3CD` | Text highlight, selected text background |

### Semantic

| Role | Hex | Usage |
|------|-----|-------|
| Success | `#2d6a4f` | Subscription confirmed, form success |
| Warning | `#b45309` | Content warnings |
| Error | `#c0392b` | Form errors, required fields |
| Info | `#4a6fa5` | Informational callouts |

## 3. Typography Rules

**Font families:**
- **Headings:** `"Playfair Display", Georgia, "Times New Roman", "Noto Serif", serif`
- **Body:** `"Source Sans 3", "Source Sans Pro", system-ui, -apple-system, "Segoe UI", sans-serif`
- **Monospace:** `"JetBrains Mono", "Fira Code", "SFMono-Regular", Consolas, monospace`

### Hierarchy

| Role | Font | Size | Weight | Line-Height | Letter-Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display | Serif | 52px / 3.25rem | 700 | 1.15 | -0.02em | Feature article headlines |
| H1 | Serif | 40px / 2.5rem | 700 | 1.2 | -0.015em | Article titles |
| H2 | Serif | 30px / 1.875rem | 700 | 1.25 | -0.01em | Section headers within articles |
| H3 | Serif | 24px / 1.5rem | 600 | 1.3 | -0.005em | Subsection headers |
| H4 | Sans-serif | 18px / 1.125rem | 600 | 1.4 | 0.01em | Minor headers, sidebar titles |
| Body | Sans-serif | 18px / 1.125rem | 400 | 1.7 | 0 | Primary reading text |
| Body Small | Sans-serif | 16px / 1rem | 400 | 1.6 | 0 | UI text, navigation |
| Caption | Sans-serif | 14px / 0.875rem | 400 | 1.5 | 0.01em | Image captions, metadata |
| Byline | Sans-serif | 14px / 0.875rem | 500 | 1.4 | 0.03em | Author names, dates |
| Pull Quote | Serif | 28px / 1.75rem | 400 | 1.4 | 0 | Italicised, indented block quotes |

**Principles:**
- Body text is 18px, not 16px — optimised for sustained reading
- Line-height of 1.7 provides generous inter-line spacing
- Content column: max-width 680px (approximately 65–75 characters per line)
- Paragraph spacing: 1.5em (margin-bottom on `<p>`)
- First-line indent OR paragraph spacing, never both
- Drop caps: optional on article opening, 3-line height, serif font, weight 400

## 4. Component Stylings

### Buttons

**Primary Button:**

```css
background: #1a1a1a
color: #FAF8F5
padding: 12px 32px
border: none
border-radius: 4px
font-family: "Source Sans 3", system-ui, sans-serif
font-size: 15px
font-weight: 600
letter-spacing: 0.02em
cursor: pointer
transition: background 150ms ease

:hover    → background: #333333
:active   → background: #000000
:focus    → outline: 2px solid #4a6fa5; outline-offset: 2px
:disabled → background: #cccccc; color: #999999; cursor: not-allowed
```

**Secondary Button:**

```css
background: transparent
color: #1a1a1a
padding: 12px 32px
border: 1.5px solid #1a1a1a
border-radius: 4px
font-size: 15px
font-weight: 600

:hover    → background: #1a1a1a; color: #FAF8F5
:active   → background: #000000; color: #FAF8F5
:disabled → border-color: #cccccc; color: #999999
```

**Ghost Button (text link style):**

```css
background: transparent
color: #4a6fa5
padding: 8px 0
border: none
font-size: 15px
font-weight: 500
text-decoration: underline
text-underline-offset: 3px
text-decoration-thickness: 1px

:hover    → color: #364f75; text-decoration-thickness: 2px
:active   → color: #2a3d5c
```

### Inputs

```css
background: #FFFFFF
border: 1px solid #E8E4DF
border-radius: 4px
padding: 12px 16px
font-family: "Source Sans 3", system-ui, sans-serif
font-size: 16px
color: #1a1a1a
transition: border-color 150ms ease

:hover       → border-color: #999999
:focus       → border-color: #4a6fa5; box-shadow: 0 0 0 3px rgba(74, 111, 165, 0.1)
:error       → border-color: #c0392b
::placeholder → color: #999999
:disabled    → background: #F2EFE9; color: #999999
```

### Links (inline text)

```css
color: #4a6fa5
text-decoration: underline
text-decoration-color: rgba(74, 111, 165, 0.3)
text-underline-offset: 3px
text-decoration-thickness: 1px
transition: text-decoration-color 150ms ease

:hover   → text-decoration-color: #4a6fa5; text-decoration-thickness: 2px
:active  → color: #364f75
:visited → color: #6b5b8a (optional)
```

### Cards (article cards)

```css
background: transparent
border: none
padding: 0
margin-bottom: 48px

Article card layout:
  - Optional: full-width image (aspect 16:9 or 3:2), no border-radius
  - Category label: 12px/600, uppercase, letter-spacing 0.08em, colour #4a6fa5
  - Title: serif, 24px/700, colour #1a1a1a, margin-top 12px
  - Excerpt: 16px/400, colour #666666, line-height 1.6, margin-top 8px
  - Byline: 14px/500, colour #999999, margin-top 12px

:hover → title colour changes to #4a6fa5 (linked articles)
```

### Navigation

```css
Top bar:
  background: #FAF8F5
  border-bottom: 1px solid #E8E4DF
  height: 60px
  padding: 0 24px

Logo/masthead:
  font-family: "Playfair Display", serif
  font-size: 24px
  font-weight: 700
  color: #1a1a1a
  letter-spacing: -0.02em

Nav links:
  font-family: "Source Sans 3", sans-serif
  font-size: 14px
  font-weight: 500
  color: #666666
  letter-spacing: 0.03em
  text-transform: uppercase
  :hover  → color: #1a1a1a
  :active → color: #4a6fa5
```

### Pull Quotes

```css
font-family: "Playfair Display", serif
font-size: 28px
font-style: italic
font-weight: 400
line-height: 1.4
color: #1a1a1a
border-left: 3px solid #E8E4DF
padding-left: 24px
margin: 48px 0
```

### Code Blocks

```css
background: #F2EFE9
border: 1px solid #E8E4DF
border-radius: 4px
padding: 20px 24px
font-family: "JetBrains Mono", monospace
font-size: 14px
line-height: 1.6
color: #2d2d2d
overflow-x: auto
```

## 5. Layout Principles

### Spacing Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--space-1` | 4px | Inline icon gaps |
| `--space-2` | 8px | Tight component spacing |
| `--space-3` | 12px | Caption spacing, byline gaps |
| `--space-4` | 16px | Standard component padding |
| `--space-5` | 24px | Card padding, pull quote indent |
| `--space-6` | 32px | Form field spacing |
| `--space-7` | 48px | Section breaks, article card gaps |
| `--space-8` | 64px | Major section separation |
| `--space-9` | 96px | Hero vertical padding |
| `--space-10` | 128px | Page-level top margin |

### Content Width

| Element | Max Width | Behaviour |
|---------|-----------|-----------|
| Body text | 680px | Centred, the primary content column |
| Images | 900px | Can exceed text column for visual impact |
| Full-bleed images | 100vw | Edge-to-edge, break out of container |
| Code blocks | 780px | Slightly wider than text for readability |
| Overall container | 1080px | Maximum page width including margins |

### Grid

- Single-column layout for articles (680px content)
- Two-column grid for index/listing pages (article cards)
- No sidebar during article reading — distraction-free
- Optional: sticky table of contents in left margin on wide screens (≥1280px)

### Whitespace Philosophy

Whitespace is the defining characteristic of this system. Every element has room to breathe. Paragraphs are spaced generously. Section breaks are visually clear. The reading experience is never cluttered, never cramped. When in doubt, add more whitespace — it always improves readability.

### Border-Radius Scale

| Token | Value | Usage |
|-------|-------|-------|
| `--radius-sm` | 2px | Tags, inline code |
| `--radius-md` | 4px | Buttons, inputs, code blocks |
| `--radius-lg` | 8px | Newsletter signup cards |
| `--radius-full` | 9999px | Author avatars |

Minimal rounding throughout — the editorial aesthetic favours clean, near-square edges.

## 6. Depth & Elevation

| Level | Name | CSS Box-Shadow | Usage |
|-------|------|---------------|-------|
| 0 | Flat | `none` | Almost everything — the default |
| 1 | Raised | `0 1px 4px rgba(0, 0, 0, 0.04)` | Newsletter signup card, floating TOC |
| 2 | Elevated | `0 4px 16px rgba(0, 0, 0, 0.06)` | Image lightbox, expanded footnote |
| 3 | Overlay | `0 12px 32px rgba(0, 0, 0, 0.1)` | Modal dialogs, share menu |

**Elevation principles:**
- Shadows are rare in this system — flat is the overwhelming default
- When shadows are used, they are soft and warm (neutral black, low opacity)
- No coloured shadows, no inner shadows
- Borders (`#E8E4DF`) are preferred over shadows for separation
- Modal backdrop: `rgba(0, 0, 0, 0.25)` — very light, keeping the calm atmosphere

## 7. Do's and Don'ts

### Do's

1. **Do** cap body text at 680px width — this is the single most important rule for readability
2. **Do** use 18px body text with 1.7 line-height — larger and more spaced than typical web defaults
3. **Do** let images breathe — full-bleed or with generous margins, never cramped inline
4. **Do** use the serif/sans-serif pairing consistently: serif for headings, sans-serif for body
5. **Do** maintain generous paragraph spacing (1.5em) for scannable long-form content
6. **Do** use the warm off-white (`#FAF8F5`) background for sustained reading comfort
7. **Do** keep navigation minimal during article reading — the content is the experience
8. **Do** use pull quotes to break up long articles (every 4–6 paragraphs maximum)

### Don'ts

1. **Don't** exceed 680px content width for body text — wider lines increase reading fatigue
2. **Don't** use more than two typefaces (serif headings + sans-serif body) — no third face
3. **Don't** add decorative animations or hover effects to article content
4. **Don't** use sidebars, widgets, or ads that compete with the reading column
5. **Don't** use coloured backgrounds for body text sections — stick to `#FAF8F5` and `#FFFFFF`
6. **Don't** reduce body text below 16px on any viewport — readability is non-negotiable
7. **Don't** use justified text alignment — left-aligned only, to avoid uneven word spacing
8. **Don't** place more than one CTA per article view — the focus is reading, not converting

## 8. Responsive Behaviour

### Breakpoints

| Name | Range | Content Width | Side Padding |
|------|-------|--------------|-------------|
| Mobile | 0–767px | 100% | 20px |
| Tablet | 768–1023px | 680px | auto (centred) |
| Desktop | 1024–1279px | 680px | auto (centred) |
| Wide | ≥1280px | 680px + optional side TOC | auto (centred) |

### Touch Targets

- Minimum tap target: 44×44px
- Navigation links: padded to 48px height on mobile
- Share buttons: minimum 44×44px with 8px gaps

### Mobile-Specific Rules

- Content width: full viewport minus 40px total padding
- Body text: remains 18px (never reduce for mobile — readability first)
- H1: reduces to 32px, H2 to 24px
- Images: full width, may bleed to viewport edges
- Pull quotes: reduce to 22px, left border maintained
- Navigation: collapses to hamburger menu with full-screen overlay
- Sticky TOC: hidden on mobile; replaced by a top "Jump to section" dropdown
- Article cards in listing: stack single-column, image on top
- Footer: stack all columns vertically, generous 32px gaps
- Reading progress bar (optional): thin 2px line at top of viewport in `#4a6fa5`

## 9. Agent Prompt Guide

### Quick Colour Reference

| CSS Variable | Hex | Role |
|-------------|-----|------|
| `--color-bg` | `#FAF8F5` | Warm off-white page background |
| `--color-surface` | `#FFFFFF` | Cards, inputs, overlays |
| `--color-surface-dark` | `#F2EFE9` | Code blocks, pull quote bg |
| `--color-text` | `#1a1a1a` | Headings |
| `--color-text-body` | `#2d2d2d` | Article body text |
| `--color-text-secondary` | `#666666` | Captions, bylines |
| `--color-text-tertiary` | `#999999` | Footnotes, deemphasised |
| `--color-link` | `#4a6fa5` | Inline links, active nav |
| `--color-link-hover` | `#364f75` | Hovered links |
| `--color-border` | `#E8E4DF` | Dividers, separators |
| `--color-highlight` | `#FFF3CD` | Text selection, highlights |
| `--color-success` | `#2d6a4f` | Success states |
| `--color-error` | `#c0392b` | Error states |

### Ready-to-Use Prompts

**Prompt 1 — Article page:**
> Build an article page following DESIGN.md. Page background #FAF8F5 with a minimal top navigation bar (60px, #FAF8F5, 1px bottom border #E8E4DF). Masthead in Playfair Display 24px/700. Article container centred at 680px max-width. Category label at top: 12px uppercase in #4a6fa5. Title in Playfair Display 40px/700/1.2 line-height in #1a1a1a. Byline: 14px/500 in #999999. Body text: Source Sans 3, 18px/400/1.7 line-height in #2d2d2d. Images can break out to 900px. Include a pull quote (Playfair Display italic 28px with 3px left border in #E8E4DF). Inline links in #4a6fa5 with subtle underlines.

**Prompt 2 — Article listing/index page:**
> Create a blog index page following DESIGN.md. Background #FAF8F5, same minimal nav. Two-column grid of article cards (max 1080px container). Each card: optional 16:9 image, category label (12px uppercase #4a6fa5), title in Playfair Display 24px/700 #1a1a1a (hover → #4a6fa5), excerpt in 16px/400 #666666, byline in 14px #999999. Cards separated by 48px vertical gap. No borders or shadows on cards — whitespace handles separation. Top of page: featured article with larger treatment (full-width image, 36px title).

**Prompt 3 — Newsletter signup page:**
> Build a newsletter signup page following DESIGN.md. Centred at 560px max-width on #FAF8F5 background. Heading in Playfair Display 36px/700. Description in Source Sans 3 18px/1.7 #2d2d2d. Email input: 16px, #FFFFFF background, 1px #E8E4DF border, 4px radius. Focus state: #4a6fa5 border with subtle ring. Subscribe button: #1a1a1a background, #FAF8F5 text, 4px radius. Below: "No spam" reassurance in 14px #999999. The entire form sits in a #FFFFFF card with 48px padding and a barely-there shadow (0 1px 4px rgba(0,0,0,0.04)).

<!--
Style archetype by AI DevOps (https://aidevops.sh)
DESIGN.md format: https://stitch.withgoogle.com/docs/design-md/overview
Not based on any specific brand. Use as a starting point for your project.
-->
