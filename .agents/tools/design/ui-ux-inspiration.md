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

Run when no `brand-identity.md` exists or user requests a rebrand. People describe preferences poorly but recognise them instantly -- use concrete examples.

### Step 1: Present Curated Examples

Show 16 URLs across 4 style categories. User picks what resonates.

| Category | Site | Why |
|----------|------|-----|
| Minimal / Clean | https://linear.app | Monochrome, generous whitespace, sharp typography |
| Minimal / Clean | https://notion.so | Neutral tones, content-first, subtle UI chrome |
| Minimal / Clean | https://stripe.com | Gradient accents on clean white, precise grid |
| Minimal / Clean | https://vercel.com | Dark-mode-first, monospace accents, developer aesthetic |
| Bold / Expressive | https://gumroad.com | Saturated colours, playful illustrations, strong CTAs |
| Bold / Expressive | https://figma.com | Vibrant gradients, rounded shapes, energetic motion |
| Bold / Expressive | https://pitch.com | Rich colour blocking, editorial typography, confident layout |
| Bold / Expressive | https://framer.com | Dark canvas, neon accents, cinematic scroll animations |
| Editorial | https://medium.com | Serif headings, reading-optimised line length, minimal distraction |
| Editorial | https://substack.com | Newsletter-native, author-centric, typographic hierarchy |
| Editorial | https://arstechnica.com | Dense information architecture, clear section hierarchy |
| Editorial | https://the-pudding.cool | Data-driven storytelling, immersive scroll, custom visualisations |
| Craft / Premium | https://apple.com | Product-hero imagery, restrained palette, cinematic pacing |
| Craft / Premium | https://rapha.cc | Photography-led, muted earth tones, luxury spacing |
| Craft / Premium | https://aesop.com | Warm neutrals, serif type, tactile texture |
| Craft / Premium | https://arc.net | Fluid animation, translucent layers, spatial UI |

### Step 2: User Selection

> Which 2-4 of these sites feel closest to what you want? You can also share any other URLs you admire -- they don't need to be in the same industry.

### Step 3: Extract Patterns from Choices

For each selected URL, run URL study (below) then synthesise:

- **Colour**: warm/cool, saturated/muted, light/dark
- **Typography**: serif/sans/mono, tight/loose tracking, heading weight
- **Layout**: dense/spacious, grid/freeform, content-width
- **Interaction**: minimal/animated, subtle/bold transitions
- **Tone**: formal/casual, technical/approachable, minimal/decorative

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

Extract computed styles from representative elements in each category:

| Category | Extract |
|----------|---------|
| Colours | Backgrounds (primary, secondary, card/surface), text (heading, body, muted), accents (action, links, highlights), borders/dividers, gradients, dark mode palette |
| Typography | Font families (heading, body, code, UI), sizes (h1-h6, body, small, caption), weights, line heights, letter spacing, text transforms |
| Layout | Max content width, container padding, grid (columns, gutter, breakpoints), section spacing, header/nav, footer |
| Buttons/Forms | Button variants (primary, secondary, ghost, destructive) with sizing, radius, all states. Input fields with height, border, padding, placeholder colour, all states. Select/dropdown, checkbox/radio. Form layout pattern. Validation styling |
| Iconography | Library (Lucide, Heroicons, Phosphor, custom SVG), sizing scale, colour treatment, usage pattern |
| Imagery | Photography style, aspect ratios, image treatment (corners, shadows, overlays, filters), placeholder/loading |
| Copy Tone | Heading style (question, statement, imperative, playful), CTA patterns, error tone, microcopy style |

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
2. Run URL study per URL -- batches of 4 (Playwright concurrency limit), 2s delay, 30s timeout per page, skip failures
3. Aggregate: most common colour palettes (cluster by hue/saturation), font families (rank by frequency), layout patterns, button/form style clusters
4. Generate "You gravitate toward..." synthesis (top 3 patterns), notable outliers, recommended palette and typography
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
