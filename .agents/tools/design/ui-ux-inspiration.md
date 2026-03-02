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

1. **Check brand identity** -- does `brand-identity.md` exist for this project? If yes, use it. If no, run the brand identity interview.
2. **Consult catalogue** -- check `ui-ux-catalogue.toon` for matching style presets and palettes.
3. **Check inspiration** -- does the user have reference URLs? If yes, run URL study. If no, present curated examples from `design-inspiration.md`.
4. **Apply quality gates** -- validate extracted patterns against accessibility (WCAG 2.1 AA), performance (no layout shift from web fonts), and platform conventions (Apple HIG / Material Design).

<!-- AI-CONTEXT-END -->

## Brand Identity Interview

Run this when a project has no `brand-identity.md` or the user requests a rebrand.

**Goal**: Discover the user's visual preferences through concrete examples rather than abstract questions. People describe what they like poorly but recognise it instantly.

### Step 1: Present Curated Examples

Show 16 example URLs across 4 style categories. The user picks what resonates.

**Minimal / Clean**

| Site | Why it's here |
|------|---------------|
| https://linear.app | Monochrome palette, generous whitespace, sharp typography |
| https://notion.so | Neutral tones, content-first layout, subtle UI chrome |
| https://stripe.com | Gradient accents on clean white, precise grid |
| https://vercel.com | Dark-mode-first, monospace accents, developer aesthetic |

**Bold / Expressive**

| Site | Why it's here |
|------|---------------|
| https://gumroad.com | Saturated colours, playful illustrations, strong CTAs |
| https://figma.com | Vibrant gradients, rounded shapes, energetic motion |
| https://pitch.com | Rich colour blocking, editorial typography, confident layout |
| https://framer.com | Dark canvas, neon accents, cinematic scroll animations |

**Editorial / Content-Rich**

| Site | Why it's here |
|------|---------------|
| https://medium.com | Serif headings, reading-optimised line length, minimal distraction |
| https://substack.com | Newsletter-native layout, author-centric, typographic hierarchy |
| https://arstechnica.com | Dense information architecture, clear section hierarchy |
| https://the-pudding.cool | Data-driven storytelling, immersive scroll, custom visualisations |

**Craft / Premium**

| Site | Why it's here |
|------|---------------|
| https://apple.com | Product-hero imagery, restrained palette, cinematic pacing |
| https://rapha.cc | Photography-led, muted earth tones, luxury spacing |
| https://aesop.com | Warm neutrals, serif type, tactile texture |
| https://arc.net | Fluid animation, translucent layers, spatial UI |

### Step 2: User Selection

Ask the user:

> Which 2-4 of these sites feel closest to what you want? You can also share any other URLs you admire -- they don't need to be in the same industry.

### Step 3: Extract Patterns from Choices

For each selected URL, run the URL study workflow (below) and then synthesise:

- **Colour direction**: warm/cool, saturated/muted, light/dark preference
- **Typography direction**: serif/sans/mono, tight/loose tracking, heading weight
- **Layout direction**: dense/spacious, grid/freeform, content-width preference
- **Interaction direction**: minimal/animated, subtle/bold transitions
- **Tone direction**: formal/casual, technical/approachable, minimal/decorative

### Step 4: Generate Brand Identity

Write findings to `tools/design/brand-identity.md` with:

- Primary and secondary colour palette (hex values)
- Typography stack (font families, sizes, weights, line heights)
- Spacing scale (base unit, common multiples)
- Component style notes (border radius, shadow depth, button style)
- Tone and voice summary
- Reference URLs with extracted screenshots
- Date generated and source session

## URL Study Workflow

Full-render extraction of a single URL using Playwright. Use this for any site the user wants to study.

### Extraction Checklist

Use Playwright (`tools/browser/browser-automation.md`) to visit the URL and extract:

**Colours**

- Background colours (primary, secondary, card/surface)
- Text colours (heading, body, muted/secondary)
- Accent/brand colours (primary action, links, highlights)
- Border and divider colours
- Gradient definitions (if used)
- Dark mode palette (if the site supports it)

**Typography**

- Font families (heading, body, code/mono, UI/label)
- Font sizes (h1-h6, body, small, caption)
- Font weights used (and where each weight appears)
- Line heights and letter spacing
- Text transform patterns (uppercase labels, sentence case headings)

**Layout**

- Max content width and container padding
- Grid system (columns, gutter, breakpoints if detectable)
- Section spacing (vertical rhythm between major sections)
- Header height and navigation pattern (sticky, hamburger, sidebar)
- Footer structure

**Buttons and Forms**

- Button variants (primary, secondary, ghost, destructive)
- Button sizing (height, padding, font size, border radius)
- Button states: default, hover, active, focus, disabled
- Input field styling (height, border, padding, placeholder colour)
- Input states: default, focus, error, disabled, filled
- Select/dropdown styling
- Checkbox and radio styling
- Form layout pattern (stacked, inline, floating labels)
- Validation message styling (position, colour, icon)

**Iconography**

- Icon library (Lucide, Heroicons, Phosphor, custom SVG)
- Icon sizing scale
- Icon colour treatment (monochrome, multi-colour, accent-matched)
- Icon usage pattern (standalone, inline with text, button icons)

**Imagery**

- Photography style (product, lifestyle, abstract, illustration)
- Image aspect ratios used
- Image treatment (rounded corners, shadows, overlays, filters)
- Placeholder/loading pattern

**Copy Tone**

- Heading style (question, statement, imperative, playful)
- CTA wording patterns (action verbs, urgency, benefit-led)
- Error message tone (technical, friendly, apologetic)
- Microcopy style (tooltips, empty states, loading messages)

### Extraction Method

```text
1. Navigate to URL with Playwright (headed mode for full render)
2. Wait for fonts and images to load (networkidle)
3. Take full-page screenshot for reference
4. Extract computed styles from key elements:
   - document.querySelectorAll('h1,h2,h3,h4,h5,h6,p,a,button,input,select,textarea')
   - getComputedStyle() for each: font-family, font-size, font-weight,
     line-height, letter-spacing, color, background-color, border,
     border-radius, padding, margin, box-shadow
5. Extract CSS custom properties (design tokens):
   - getComputedStyle(document.documentElement) for all --* properties
6. Check for dark mode: prefers-color-scheme media query or toggle
7. Capture button/input hover states via Playwright hover actions
8. Record all findings in structured format
```

### Output Format

```markdown
## URL Study: {url}
**Date**: {ISO date}
**Screenshot**: {path to saved screenshot}

### Colours
| Role | Hex | Usage |
|------|-----|-------|
| Background (primary) | #ffffff | Page background |
| ... | ... | ... |

### Typography
| Element | Family | Size | Weight | Line Height |
|---------|--------|------|--------|-------------|
| h1 | Inter | 48px | 700 | 1.2 |
| ... | ... | ... | ... | ... |

### Buttons
| Variant | BG | Text | Border | Radius | Hover BG |
|---------|-----|------|--------|--------|----------|
| Primary | #000 | #fff | none | 8px | #333 |
| ... | ... | ... | ... | ... | ... |

### Forms
| Element | Height | Border | Radius | Focus Border |
|---------|--------|--------|--------|--------------|
| Input | 40px | 1px #e0e0e0 | 6px | 2px #0066ff |
| ... | ... | ... | ... | ... |

### Layout
- Max width: {value}
- Grid: {columns} / {gutter}
- Section spacing: {value}

### Notes
{Observations about patterns, unique treatments, accessibility concerns}
```

## Bulk URL Import

Process a bookmarks folder export or a plain list of URLs and generate a pattern summary.

### Input Formats

- **Bookmarks HTML**: Standard browser export (`<DT><A HREF="...">`)
- **Plain text**: One URL per line
- **Markdown list**: `- https://example.com` or `- [Label](https://example.com)`

### Workflow

```text
1. Parse input to extract URLs (ignore non-http entries)
2. Deduplicate and validate (HEAD request, skip 4xx/5xx)
3. For each valid URL, run the URL study extraction (above)
   - Process in batches of 4 (Playwright concurrency limit)
   - Skip URLs that fail to load within 30 seconds
4. Aggregate findings across all URLs:
   - Most common colour palettes (cluster by hue/saturation)
   - Most common font families (rank by frequency)
   - Layout pattern distribution (content width, grid usage)
   - Button/form style clusters
5. Generate pattern summary with:
   - "You gravitate toward..." synthesis (top 3 patterns)
   - Outliers worth noting (unique treatments from specific URLs)
   - Recommended palette and typography based on frequency analysis
6. Write summary to brand-identity.md or append to existing
```

### Concurrency and Rate Limiting

- Maximum 4 concurrent Playwright pages
- 2-second delay between navigation starts (avoid rate limiting)
- 30-second timeout per page (skip slow sites)
- Total batch timeout: 10 minutes for up to 20 URLs

## Quality Gates

Before finalising any brand identity or design recommendation, validate against:

### Accessibility (WCAG 2.1 AA)

- All text/background colour combinations meet 4.5:1 contrast ratio (3:1 for large text)
- Focus indicators are visible (not just colour change)
- Interactive elements have minimum 44x44px touch targets
- Font sizes are at least 16px for body text

### Performance

- Recommended fonts are available on Google Fonts or system font stacks (avoid obscure web fonts that add load time)
- Colour palette works without gradients (graceful degradation)
- Layout doesn't depend on JavaScript for initial render

### Platform Conventions

- iOS projects: cross-reference with Apple HIG (`developer.apple.com/design/human-interface-guidelines`)
- Android projects: cross-reference with Material Design (`m3.material.io`)
- Web projects: check against common component library defaults (shadcn/ui, Radix)

## Related

- `tools/design/design-inspiration.md` -- 60+ curated UI/UX resource galleries
- `tools/design/ui-ux-catalogue.toon` -- style presets and palette data
- `tools/design/brand-identity.md` -- output destination for brand profiles
- `tools/browser/browser-automation.md` -- Playwright tool selection and usage
- `tools/ui/tailwind-css.md` -- implementing extracted styles in Tailwind
- `tools/ui/shadcn.md` -- component library for applying design tokens
- `tools/ui/ui-skills.md` -- opinionated UI constraints
- `mobile-app-dev/ui-design.md` -- mobile-specific design standards
- `workflows/ui-verification.md` -- visual regression testing
