---
description: UI/UX inspiration skill - brand identity interview, URL study, pattern extraction
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: false
  webfetch: true
  task: true
model: sonnet
---

# UI/UX Inspiration Skill

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Extract design patterns from real websites to inform brand identity and UI decisions
- **Trigger**: New project, rebrand, or "I need design inspiration"
- **Output**: `tools/design/brand-identity.md` (per-project brand profile)
- **Data**: `tools/design/ui-ux-catalogue.toon` (styles, palettes, pattern library)
- **Resources**: `tools/design/design-inspiration.md` (60+ curated galleries)
- **Browser**: Playwright full-render extraction (see `tools/browser/browser-automation.md`)

**Design workflow** (apply in order):

1. **Check brand identity** -- does `brand-identity.md` exist? If yes, use it. If no, run brand identity interview.
2. **Consult catalogue** -- check `ui-ux-catalogue.toon` for matching style presets and palettes.
3. **Check inspiration** -- user has reference URLs? Run URL study. No URLs? Present curated examples from `design-inspiration.md`.
4. **Apply quality gates** -- validate against accessibility (WCAG 2.1 AA), performance, and platform conventions.

<!-- AI-CONTEXT-END -->

## Brand Identity Interview

Run when a project has no `brand-identity.md` or user requests a rebrand. People describe preferences poorly but recognise them instantly — use concrete examples.

### Step 1: Present Curated Examples

Show 16 URLs across 4 style categories. User picks what resonates.

**Minimal / Clean**

| Site | Why |
|------|-----|
| https://linear.app | Monochrome, generous whitespace, sharp typography |
| https://notion.so | Neutral tones, content-first, subtle UI chrome |
| https://stripe.com | Gradient accents on clean white, precise grid |
| https://vercel.com | Dark-mode-first, monospace accents, developer aesthetic |

**Bold / Expressive**

| Site | Why |
|------|-----|
| https://gumroad.com | Saturated colours, playful illustrations, strong CTAs |
| https://figma.com | Vibrant gradients, rounded shapes, energetic motion |
| https://pitch.com | Rich colour blocking, editorial typography, confident layout |
| https://framer.com | Dark canvas, neon accents, cinematic scroll animations |

**Editorial / Content-Rich**

| Site | Why |
|------|-----|
| https://medium.com | Serif headings, reading-optimised line length, minimal distraction |
| https://substack.com | Newsletter-native, author-centric, typographic hierarchy |
| https://arstechnica.com | Dense information architecture, clear section hierarchy |
| https://the-pudding.cool | Data-driven storytelling, immersive scroll, custom visualisations |

**Craft / Premium**

| Site | Why |
|------|-----|
| https://apple.com | Product-hero imagery, restrained palette, cinematic pacing |
| https://rapha.cc | Photography-led, muted earth tones, luxury spacing |
| https://aesop.com | Warm neutrals, serif type, tactile texture |
| https://arc.net | Fluid animation, translucent layers, spatial UI |

### Step 2: User Selection

> Which 2-4 of these sites feel closest to what you want? You can also share any other URLs you admire -- they don't need to be in the same industry.

### Step 3: Extract Patterns from Choices

For each selected URL, run URL study (below) then synthesise:

- **Colour direction**: warm/cool, saturated/muted, light/dark
- **Typography direction**: serif/sans/mono, tight/loose tracking, heading weight
- **Layout direction**: dense/spacious, grid/freeform, content-width
- **Interaction direction**: minimal/animated, subtle/bold transitions
- **Tone direction**: formal/casual, technical/approachable, minimal/decorative

### Step 4: Generate Brand Identity

Write to `tools/design/brand-identity.md`:

- Primary and secondary colour palette (hex values)
- Typography stack (families, sizes, weights, line heights)
- Spacing scale (base unit, common multiples)
- Component style notes (border radius, shadow depth, button style)
- Tone and voice summary
- Reference URLs with extracted screenshots
- Date generated and source session

## URL Study Workflow

Full-render extraction of a single URL using Playwright (`tools/browser/browser-automation.md`).

### Extraction Checklist

For each category, extract computed styles from representative elements:

**Colours**: backgrounds (primary, secondary, card/surface), text (heading, body, muted), accents (primary action, links, highlights), borders/dividers, gradients, dark mode palette.

**Typography**: font families (heading, body, code, UI), sizes (h1-h6, body, small, caption), weights and where used, line heights, letter spacing, text transforms.

**Layout**: max content width, container padding, grid system (columns, gutter, breakpoints), section spacing, header height/nav pattern, footer structure.

**Buttons and Forms**: button variants (primary, secondary, ghost, destructive) with sizing, radius, and all states (default, hover, active, focus, disabled). Input fields with height, border, padding, placeholder colour, and states (default, focus, error, disabled, filled). Select/dropdown, checkbox/radio styling. Form layout pattern (stacked, inline, floating labels). Validation message styling.

**Iconography**: library (Lucide, Heroicons, Phosphor, custom SVG), sizing scale, colour treatment, usage pattern (standalone, inline, button icons).

**Imagery**: photography style, aspect ratios, image treatment (corners, shadows, overlays, filters), placeholder/loading pattern.

**Copy Tone**: heading style (question, statement, imperative, playful), CTA wording patterns, error message tone, microcopy style (tooltips, empty states, loading).

### Extraction Method

```text
1. Navigate with Playwright (headed mode, full render)
2. Wait for fonts/images (networkidle)
3. Take full-page screenshot for reference
4. Extract computed styles from representative elements:
   - Sample across headings, body text, containers/cards, form controls,
     navigation, interactive elements (buttons, links, chips, badges)
   - Skip hidden/offscreen/zero-size nodes; deduplicate by normalised style signature
   - Target 20-40 unique pattern nodes, prioritising above-the-fold and repeated components
   - Record per pattern: font-family, font-size, font-weight, line-height,
     letter-spacing, color, background-color, border, border-radius, padding,
     margin, box-shadow
5. Extract CSS custom properties (design tokens) from document.documentElement
6. Check dark mode: prefers-color-scheme media query or toggle
7. Capture button/input hover states via Playwright hover actions
8. Record all findings in structured format
```

### Output Format

```markdown
## URL Study: {url}
**Date**: {ISO date}
**Screenshot**: {path}

### Colours
| Role | Hex | Usage |
|------|-----|-------|
| Background (primary) | #ffffff | Page background |

### Typography
| Element | Family | Size | Weight | Line Height |
|---------|--------|------|--------|-------------|
| h1 | Inter | 48px | 700 | 1.2 |

### Buttons
| Variant | BG | Text | Border | Radius | Hover BG |
|---------|-----|------|--------|--------|----------|
| Primary | #000 | #fff | none | 8px | #333 |

### Forms
| Element | Height | Border | Radius | Focus Border |
|---------|--------|--------|--------|--------------|
| Input | 40px | 1px #e0e0e0 | 6px | 2px #0066ff |

### Layout
- Max width: {value}
- Grid: {columns} / {gutter}
- Section spacing: {value}

### Notes
{Observations about patterns, unique treatments, accessibility concerns}
```

## Bulk URL Import

Process a bookmarks export or URL list into a pattern summary.

**Input formats**: Bookmarks HTML (`<DT><A HREF="...">`), plain text (one URL per line), markdown list (`- [Label](url)`).

**Workflow**:

1. Parse input, extract URLs (ignore non-http), deduplicate, validate (HEAD request, skip 4xx/5xx)
2. Run URL study extraction per URL — batches of 4 (Playwright concurrency limit), 2s delay between navigations, 30s timeout per page, skip failures
3. Aggregate across all URLs: most common colour palettes (cluster by hue/saturation), font families (rank by frequency), layout patterns, button/form style clusters
4. Generate summary: "You gravitate toward..." synthesis (top 3 patterns), notable outliers, recommended palette and typography from frequency analysis
5. Write to `brand-identity.md` or append to existing

**Limits**: max 4 concurrent Playwright pages, 30s per-page timeout, 10 min total for up to 20 URLs.

## Quality Gates

Validate before finalising any brand identity or design recommendation:

### Accessibility (WCAG 2.1 AA)

- Text/background contrast: 4.5:1 minimum (3:1 for large text)
- Visible focus indicators (not just colour change)
- Interactive elements: minimum 44x44px touch targets
- Body text: at least 16px

### Performance

- Prefer Google Fonts or system font stacks (avoid obscure web fonts adding load time)
- Colour palette works without gradients (graceful degradation)
- Layout doesn't depend on JavaScript for initial render

### Platform Conventions

- iOS: cross-reference Apple HIG (`developer.apple.com/design/human-interface-guidelines`)
- Android: cross-reference Material Design (`m3.material.io`)
- Web: check against common component library defaults (shadcn/ui, Radix)

## Related

- `tools/design/design-inspiration.md` -- 60+ curated UI/UX resource galleries
- `tools/design/ui-ux-catalogue.toon` -- style presets and palette data
- `tools/design/brand-identity.md` -- output destination for brand profiles
- `tools/browser/browser-automation.md` -- Playwright tool selection and usage
- `tools/ui/tailwind-css.md` -- implementing extracted styles in Tailwind
- `tools/ui/shadcn.md` -- component library for applying design tokens
- `tools/ui/ui-skills.md` -- opinionated UI constraints
- `product/ui-design.md` -- product design standards (all platforms)
- `workflows/ui-verification.md` -- visual regression testing
