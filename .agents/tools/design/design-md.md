---
name: design-md
description: >
  DESIGN.md standard -- AI-readable design system documents. Create, use, and manage
  DESIGN.md files for any project. Use when starting UI work, onboarding a new project,
  generating design tokens, or building from a brand reference.
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  webfetch: true
  task: true
model: sonnet
---

# DESIGN.md -- AI-Readable Design Systems

<!-- AI-CONTEXT-START -->

## Quick Reference

- **What**: A plain-text markdown file that captures a complete visual design system for AI agents
- **Origin**: Google Stitch (https://stitch.withgoogle.com/docs/design-md/overview)
- **Location**: `DESIGN.md` in project root (alongside `AGENTS.md`)
- **Template**: `templates/DESIGN.md.template` (skeleton for `aidevops init`)
- **Library**: `tools/design/library/` (54 brand examples + 12 style templates)
- **Preview**: `tools/design/library/_template/preview.html.template` (visual catalogue generator)
- **Palette tools**: `tools/design/colour-palette.md` (generation, spinning, narrowing)
- **CLI scripts**: `scripts/colormind-helper.sh` (palette API), `scripts/design-preview-helper.sh` (screenshot capture)

**Relationship to other design agents:**

| Agent | Role | Relationship to DESIGN.md |
|-------|------|---------------------------|
| `tools/design/brand-identity.md` | Strategic brand profile (8 dimensions) | **Upstream** -- brand decisions feed DESIGN.md generation |
| `tools/design/ui-ux-inspiration.md` | URL study + interview workflow | **Producer** -- extracts tokens that populate DESIGN.md |
| `tools/design/design-inspiration.md` | 60+ curated gallery resources | **Discovery** -- where to look for references |
| `tools/design/colour-palette.md` | Palette generation and spinning | **Tool** -- generates colour sections for DESIGN.md |
| `tools/design/library/` | Example DESIGN.md files | **Reference** -- inspiration and starting points |
| `product/ui-design.md` | Product design standards | **Constraint** -- accessibility/platform rules DESIGN.md must satisfy |
| `tools/ui/ui-skills.md` | Opinionated UI build rules | **Implementation** -- how to build what DESIGN.md specifies |
| `tools/ui/nothing-design-skill/` | Nothing-style design system | **Example** -- a complete design system in agent format |
| `tools/design/ui-ux-catalogue.toon` | 36+ UI style patterns | **Data** -- style presets that inform DESIGN.md choices |

**Workflow overview** (apply in order):

1. **Check** -- does `DESIGN.md` exist in project root? If yes, use it. If no, create one.
2. **Create** -- from scratch (interview), from URL (extraction), or from library example.
3. **Preview** -- generate `preview.html` to visually verify the design system.
4. **Iterate** -- spin palettes, adjust tokens, regenerate preview until satisfied.
5. **Build** -- hand DESIGN.md to coding agents. They read it and produce matching UI.

<!-- AI-CONTEXT-END -->

## The DESIGN.md Format

### Purpose

DESIGN.md is to visual design what AGENTS.md is to code behaviour. It's a plain-text document that AI coding agents read to generate consistent, on-brand UI. No Figma exports, no JSON schemas, no special tooling -- just markdown that LLMs read natively.

### The 9 Sections

Every DESIGN.md follows this structure. All sections are required for a complete system; partial files work but produce less consistent output.

| # | Section | What it captures | Why agents need it |
|---|---------|------------------|--------------------|
| 1 | Visual Theme & Atmosphere | Mood, density, design philosophy, key characteristics | Sets the overall direction before any specifics |
| 2 | Colour Palette & Roles | Semantic name + hex + functional role for every colour | Agents need exact values, not "use a blue" |
| 3 | Typography Rules | Font families, full hierarchy table (size, weight, line-height, spacing) | Consistent type scale across all generated components |
| 4 | Component Stylings | Buttons, cards, inputs, navigation with all states (hover, focus, active, disabled) | Agents build components -- they need the specs |
| 5 | Layout Principles | Spacing scale, grid system, container widths, whitespace philosophy | Consistent spatial rhythm |
| 6 | Depth & Elevation | Shadow system, surface hierarchy, layering rules | Visual depth without guessing |
| 7 | Do's and Don'ts | Design guardrails and anti-patterns | Prevents agents from making off-brand choices |
| 8 | Responsive Behaviour | Breakpoints, touch targets, collapsing strategy | Multi-device consistency |
| 9 | Agent Prompt Guide | Quick colour reference, ready-to-use prompts | Fast-path for agents that just need the essentials |

### Section Detail

#### 1. Visual Theme & Atmosphere

Prose description (2-4 paragraphs) covering:

- Overall mood and aesthetic direction
- What makes this design system distinctive
- Key characteristics as a bullet list with exact values

Example opening: _"A dark-mode-first developer tool interface rooted in deep purple-black backgrounds (#1f1633) that evoke late-night debugging sessions..."_

#### 2. Colour Palette & Roles

Grouped by function. Every colour has semantic name, hex, and usage description.

```markdown
### Primary Brand
- **Deep Purple** (`#1f1633`): Primary background, the defining colour of the brand

### Accent Colours
- **Lime Green** (`#c2ef4e`): High-visibility accent, CTAs, badge highlights

### Text Colours
- **Pure White** (`#ffffff`): Primary text on dark backgrounds

### Surface & Overlay
- **Glass White** (`rgba(255, 255, 255, 0.18)`): Frosted glass button backgrounds
```

#### 3. Typography Rules

Three parts: font families, hierarchy table, principles.

The hierarchy table is the core -- a complete mapping from role to exact values:

```markdown
| Role | Font | Size | Weight | Line Height | Letter Spacing | Notes |
|------|------|------|--------|-------------|----------------|-------|
| Display Hero | Dammit Sans | 88px | 700 | 1.20 | normal | Brand voice |
| Body | Rubik | 16px | 400 | 1.50 | normal | Standard text |
| Button Text | Rubik | 14px | 500-700 | 1.14 | 0.2px | uppercase |
```

#### 4. Component Stylings

Each component variant needs: background, text colour, border, radius, padding, shadow, and all interactive states.

```markdown
### Buttons

**Primary**
- Background: `#79628c`
- Text: `#ffffff`, uppercase, 14px, weight 700
- Border: `1px solid #584674`
- Radius: 13px
- Hover: elevated shadow `rgba(0,0,0,0.18) 0px 0.5rem 1.5rem`
- Focus: outline `rgb(106, 95, 193) solid 0.125rem`
```

#### 5. Layout Principles

Spacing scale, grid system, container widths, breakpoint table, whitespace philosophy.

#### 6. Depth & Elevation

Table of elevation levels with shadow values and usage:

```markdown
| Level | Treatment | Use |
|-------|-----------|-----|
| Sunken (-1) | Inset shadow | Pressed buttons |
| Flat (0) | No shadow | Default surfaces |
| Elevated (2) | `0px 10px 15px -3px` | Cards, panels |
```

#### 7. Do's and Don'ts

Explicit guardrails:

```markdown
**Do:**
- Use the 8px spacing grid for all measurements
- Apply frosted glass effect only on dark backgrounds

**Don't:**
- Never use pure black (#000000) as a background
- Never mix font families within a single component
```

#### 8. Responsive Behaviour

Breakpoint table, mobile-specific rules, touch target sizes.

#### 9. Agent Prompt Guide

Quick-reference colour table and ready-to-use prompts for common tasks:

```markdown
### Quick Colour Reference
| Token | Value | Use |
|-------|-------|-----|
| --bg-primary | #1f1633 | Page background |

### Ready-to-Use Prompts
- "Build a hero section": Use Display Hero font, primary background, lime green CTA
```

## Creating a DESIGN.md

### Method 1: From Scratch (Interview)

Best when starting a new project with no existing design.

1. Run brand identity interview (`tools/design/brand-identity.md`)
2. User selects UI style from `tools/design/ui-ux-catalogue.toon`
3. Generate colour palette (`tools/design/colour-palette.md`)
4. Browse library examples for closest match (`tools/design/library/`)
5. Synthesise into DESIGN.md using the template (`templates/DESIGN.md.template`)
6. Generate preview, iterate with user

### Method 2: From URL (Extraction)

Best when matching an existing website's look.

1. Run URL study workflow (`tools/design/ui-ux-inspiration.md` > URL Study Workflow)
2. Extract computed styles: colours, typography, spacing, components, shadows
3. Map extracted values into DESIGN.md sections
4. Fill gaps (the URL study won't capture do's/don'ts or responsive rules -- infer from patterns)
5. Generate preview, validate against source URL

### Method 3: From Library Example

Best when a known brand/style is close to what's needed.

1. Browse `tools/design/library/brands/` (55 real brand examples) or `tools/design/library/styles/` (archetype templates)
2. Copy the closest DESIGN.md into project root
3. Customise: swap colours (use `tools/design/colour-palette.md`), adjust typography, update do's/don'ts
4. Generate preview, iterate

### Method 4: From Brand Identity

Best when `brand-identity.toon` already exists in the project.

1. Read existing `context/brand-identity.toon`
2. Map brand identity dimensions to DESIGN.md sections:
   - `visual_style` + `buttons_and_forms` -> sections 1, 4, 5, 6
   - `voice_and_tone` + `copywriting_patterns` -> section 7 (do's/don'ts voice)
   - `imagery` + `iconography` -> section 7 (imagery guidelines)
   - `media_and_motion` -> sections 4 (animation states), 8 (responsive)
   - `brand_positioning` -> section 1 (atmosphere), section 9 (agent prompts)
3. Generate colour palette if only names/keywords exist
4. Populate typography from `visual_style.typography`
5. Fill component specs from `buttons_and_forms`

## Using a DESIGN.md

### For Coding Agents

Drop `DESIGN.md` in your project root. Tell the agent:

> "Build a landing page following DESIGN.md"

The agent reads the file and uses exact hex values, font specs, spacing, and component styles. No ambiguity, no "make it look nice" -- specific, reproducible output.

### For Design Review

Generate `preview.html` from the DESIGN.md to produce a visual catalogue showing:

- Colour swatches with hex values
- Typography scale samples
- Button variants with states
- Card and input examples
- Spacing scale visualisation
- Light and dark mode versions

Use `tools/design/library/_template/preview.html.template` to generate previews.

### For Screenshots

Use Playwright to render `preview.html` and capture optimised screenshots:

```text
1. Open preview.html in Playwright (1440px viewport)
2. Wait for fonts to load (networkidle)
3. Capture full-page screenshot as PNG
4. Convert to WebP (quality 90) and AVIF (quality 80) for size optimisation
5. Repeat with dark mode variant
6. Respect screenshot size limits (max 1568px longest side for AI review)
```

## Library Structure

```
tools/design/library/
├── README.md                  -- Index, disclaimer, usage guide
├── _template/
│   ├── DESIGN.md.template     -- Section skeleton with placeholders
│   └── preview.html.template  -- Parameterised HTML/CSS for visual preview
├── brands/                    -- Real brand examples (educational use)
│   ├── airbnb/DESIGN.md
│   ├── apple/DESIGN.md
│   ├── ...                    -- 55 brands total
│   └── zapier/DESIGN.md
└── styles/                    -- Archetype style templates
    ├── corporate-traditional/DESIGN.md
    ├── corporate-modern/DESIGN.md
    ├── corporate-friendly/DESIGN.md
    ├── agency-techie/DESIGN.md
    ├── agency-creative/DESIGN.md
    ├── agency-feminine/DESIGN.md
    ├── startup-bold/DESIGN.md
    ├── startup-minimal/DESIGN.md
    ├── developer-dark/DESIGN.md
    ├── editorial-clean/DESIGN.md
    ├── luxury-premium/DESIGN.md
    └── playful-vibrant/DESIGN.md
```

### Brands vs Styles

- **Brands** (`library/brands/`): Extracted from real websites. Educational reference. Shows how top companies implement their design systems. Useful for "I want something like Stripe" or "make it feel like Linear".
- **Styles** (`library/styles/`): Original archetype templates. Not tied to any brand. Generic starting points for common project types. Useful for "I need a corporate site" or "build me a developer tool dashboard".

## Browser Automation: DESIGN.md from URL

Extends the URL study workflow in `tools/design/ui-ux-inspiration.md`. Full process:

1. **Navigate** -- Playwright headed mode, wait for `networkidle`
2. **Extract** -- Computed styles from 20-40 representative elements:
   - Colours: backgrounds, text, borders, accents, gradients
   - Typography: families, sizes, weights, line-heights, letter-spacing
   - Spacing: padding, margins, gaps, container widths
   - Components: buttons, inputs, cards, navigation (all states via hover/focus simulation)
   - Shadows: box-shadow values by elevation level
   - CSS custom properties (design tokens) from `:root`
3. **Extract dark mode** -- Check `prefers-color-scheme` media query or toggle
4. **Map** -- Extracted values into DESIGN.md 9-section format
5. **Fill gaps** -- Infer do's/don'ts from observed patterns, add responsive rules from viewport testing
6. **Generate preview** -- Produce `preview.html` and validate against source
7. **Screenshot** -- Capture preview as PNG/WebP/AVIF, light and dark variants

## Related

- `tools/design/brand-identity.md` -- Strategic brand profile (upstream input)
- `tools/design/ui-ux-inspiration.md` -- URL study extraction workflow
- `tools/design/design-inspiration.md` -- 60+ curated gallery resources
- `tools/design/colour-palette.md` -- Palette generation and spinning
- `tools/design/library/README.md` -- Library index and usage
- `tools/design/ui-ux-catalogue.toon` -- 36+ UI style patterns
- `product/ui-design.md` -- Product design standards and accessibility
- `tools/ui/ui-skills.md` -- Opinionated UI build constraints
- `tools/ui/nothing-design-skill.md` -- Example: complete design system as agent
- `templates/DESIGN.md.template` -- Skeleton for `aidevops init`
- `workflows/ui-verification.md` -- Visual regression testing
