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

- **What**: Plain-text markdown capturing a complete visual design system for AI agents
- **Origin**: Google Stitch (https://stitch.withgoogle.com/docs/design-md/overview)
- **Location**: `DESIGN.md` in project root (alongside `AGENTS.md`)
- **Template**: `templates/DESIGN.md.template`
- **Library**: `tools/design/library/` (55 brand examples + 12 style templates)
- **Preview**: `tools/design/library/_template/preview.html.template`
- **Palette tools**: `tools/design/colour-palette.md`, `scripts/colormind-helper.sh`
- **Preview capture**: `scripts/design-preview-helper.sh`

**Agent relationships:**

| Agent | Role | Relationship |
|-------|------|--------------|
| `tools/design/brand-identity.md` | Strategic brand profile (8 dimensions) | **Upstream** — feeds DESIGN.md generation |
| `tools/design/ui-ux-inspiration.md` | URL study + interview workflow | **Producer** — extracts tokens |
| `tools/design/design-inspiration.md` | 60+ curated gallery resources | **Discovery** |
| `tools/design/colour-palette.md` | Palette generation and spinning | **Tool** |
| `tools/design/library/` | Example DESIGN.md files | **Reference** |
| `product/ui-design.md` | Product design standards | **Constraint** — accessibility/platform rules |
| `tools/ui/ui-skills.md` | Opinionated UI build rules | **Implementation** |
| `tools/ui/nothing-design-skill/` | Nothing-style design system | **Example** |
| `tools/design/ui-ux-catalogue.toon` | 36+ UI style patterns | **Data** |

**Workflow** (apply in order):

1. **Check** — does `DESIGN.md` exist in project root? If yes, use it. If no, create one.
2. **Create** — from scratch (interview), URL (extraction), or library example.
3. **Preview** — generate `preview.html` to visually verify the design system.
4. **Iterate** — spin palettes, adjust tokens, regenerate preview until satisfied.
5. **Build** — hand DESIGN.md to coding agents for consistent, on-brand UI output.

<!-- AI-CONTEXT-END -->

## The DESIGN.md Format

DESIGN.md is to visual design what AGENTS.md is to code behaviour — plain-text that LLMs read natively. No Figma exports, no JSON schemas.

### The 9 Sections

All sections required for a complete system; partial files work but produce less consistent output.

| # | Section | What it captures |
|---|---------|-----------------|
| 1 | Visual Theme & Atmosphere | Mood, density, design philosophy, key characteristics |
| 2 | Colour Palette & Roles | Semantic name + hex + functional role for every colour |
| 3 | Typography Rules | Font families, full hierarchy table (size, weight, line-height, spacing) |
| 4 | Component Stylings | Buttons, cards, inputs, navigation with all states (hover, focus, active, disabled) |
| 5 | Layout Principles | Spacing scale, grid system, container widths, whitespace philosophy |
| 6 | Depth & Elevation | Shadow system, surface hierarchy, layering rules |
| 7 | Do's and Don'ts | Design guardrails and anti-patterns |
| 8 | Responsive Behaviour | Breakpoints, touch targets, collapsing strategy |
| 9 | Agent Prompt Guide | Quick colour reference, ready-to-use prompts |

**Key format rules per section:**

- **Section 2**: Group by function (Primary Brand, Accent, Text, Surface). Every colour: semantic name + hex + usage.
- **Section 3**: Hierarchy table is the core — map every role to exact size/weight/line-height/letter-spacing.
- **Section 4**: Each component variant needs background, text colour, border, radius, padding, shadow, and all interactive states.
- **Section 6**: Table of elevation levels with shadow values and use cases (Sunken/Flat/Elevated).
- **Section 9**: Quick-reference colour token table + ready-to-use prompts for common tasks.

## Creating a DESIGN.md

Choose method based on what exists:

| Situation | Method | Starting point |
|-----------|--------|---------------|
| New project, no design | Interview | Brand identity → palette → library match → template |
| Match an existing site | URL extraction | `tools/design/ui-ux-inspiration.md` URL Study Workflow |
| Known brand/style | Library copy | `tools/design/library/brands/` or `library/styles/` |
| `brand-identity.toon` exists | Brand identity | Map dimensions to sections (see below) |

**Method 1 (Interview):** Brand identity interview (`tools/design/brand-identity.md`) → select UI style from `ui-ux-catalogue.toon` → generate palette (`colour-palette.md`) → copy closest library example → synthesise into template → preview + iterate.

**Method 2 (URL):** URL study workflow extracts computed styles (colours, typography, spacing, components, shadows, CSS custom properties from `:root`). Map to 9-section format. Fill gaps (do's/don'ts, responsive rules) by inference. Generate preview, validate against source. Full browser automation process: `tools/design/ui-ux-inspiration.md`.

**Method 3 (Library):** Copy closest `library/brands/` or `library/styles/` DESIGN.md into project root. Swap colours, adjust typography, update do's/don'ts. Preview + iterate.

**Method 4 (Brand identity):** Map `context/brand-identity.toon` dimensions:

- `visual_style` + `buttons_and_forms` → sections 1, 4, 5, 6
- `voice_and_tone` + `copywriting_patterns` → section 7
- `imagery` + `iconography` → section 7
- `media_and_motion` → sections 4, 8
- `brand_positioning` → sections 1, 9

## Using a DESIGN.md

**For coding agents:** Drop `DESIGN.md` in project root. Tell the agent: `"Build a landing page following DESIGN.md"`. The agent uses exact hex values, font specs, spacing, and component styles — specific, reproducible output.

**For design review:** Generate `preview.html` from `tools/design/library/_template/preview.html.template`. Shows colour swatches, typography scale, button variants, card/input examples, spacing scale, light/dark modes.

**For screenshots:** Playwright at 1440px viewport, wait `networkidle`, capture PNG, convert to WebP (quality 90) and AVIF (quality 80). Repeat for dark mode. Respect screenshot size limits (max 1568px longest side).

## Library Structure

```
tools/design/library/
├── README.md                  -- Index, disclaimer, usage guide
├── _template/
│   ├── DESIGN.md.template     -- Section skeleton with placeholders
│   └── preview.html.template  -- Parameterised HTML/CSS for visual preview
├── brands/                    -- 55 real brand examples (educational use)
│   └── {brand}/DESIGN.md
└── styles/                    -- 12 archetype style templates
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

- **Brands**: Extracted from real websites. Use for "I want something like Stripe" or "make it feel like Linear".
- **Styles**: Original archetype templates. Use for "I need a corporate site" or "build me a developer tool dashboard".

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
