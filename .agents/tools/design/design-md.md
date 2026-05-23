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

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# DESIGN.md -- AI-Readable Design Systems

<!-- AI-CONTEXT-START -->

## Quick Reference

- **What**: Plain-text markdown capturing a complete visual design system for AI agents
- **Normative spec**: [google-labs-code/design.md](https://github.com/google-labs-code/design.md) (Apache 2.0, format version `alpha`; aidevops tracks upstream changes beyond the original v0.1.0 adoption). Full spec: [`docs/spec.md`](https://github.com/google-labs-code/design.md/blob/main/docs/spec.md)
- **Format**: YAML front matter (machine-readable tokens) + Markdown body (human-readable rationale)
- **Location**: `DESIGN.md` in project root (alongside `AGENTS.md`)
- **Validator**: `npx @google/design.md lint DESIGN.md` (lint, diff, export to tailwind/dtcg, spec; use the `designmd` bin alias in Windows package scripts)
- **Template**: `templates/DESIGN.md.template`
- **Library**: `tools/design/library/` (55 brand examples, style templates, and report presentation presets)
- **Preview**: `tools/design/library/_template/preview.html.template`
- **Palette tools**: `tools/design/colour-palette.md`, `scripts/colormind-helper.sh`
- **Preview capture**: `scripts/design-preview-helper.sh`

**Agent relationships:**

Upstream `@google/design.md` v0.1.0 was reviewed as the initial open-source release of the CLI/linter. The current aidevops schema guidance already covers the release's agent-safe JSON output, `designmd` Windows alias, lint/diff/export/spec commands, and alpha-format token model; continue watching for v1 or schema-breaking releases before changing templates.

| Agent | Role | Relationship |
|-------|------|--------------|
| `tools/design/brand-identity.md` | Strategic brand profile (8 dimensions) | **Upstream** — feeds DESIGN.md generation |
| `tools/design/ui-ux-inspiration.md` | URL study + interview workflow | **Discovery** — finds and studies references |
| `tools/design/design-md-from-links.md` | Website/brand links to DESIGN.md | **Producer** — extracts, validates, previews, and hands off tokens |
| `tools/design/report-presentation.md` | Report presentation tokens/components | **Specialisation** — Markdown, HTML, and PDF-ready reports |
| `tools/design/design-inspiration.md` | 60+ curated gallery resources | **Discovery** |
| `tools/design/colour-palette.md` | Palette generation and spinning | **Tool** |
| `tools/design/library/` | Example DESIGN.md files | **Reference** |
| `product/ui-design.md` | Product design standards | **Constraint** — accessibility/platform rules |
| `tools/ui/ui-skills.md` | Opinionated UI build rules | **Implementation** |
| `tools/ui/nothing-design-skill/` | Nothing-style design system | **Example** |
| `tools/design/ui-ux-catalogue.toon` | 36+ UI style patterns | **Data** |

**Workflow** (apply in order):

1. **Check** — does `DESIGN.md` exist in project root? If yes, use it. If no, create one.
2. **Create** — from scratch (interview), links (`tools/design/design-md-from-links.md`), report presentation (`tools/design/report-presentation.md`), or library example.
3. **Validate** — run `npx @google/design.md lint DESIGN.md`. Zero errors, warnings reviewed.
4. **Preview** — generate `preview.html` to visually verify the design system.
5. **Iterate** — spin palettes, adjust tokens, regenerate preview until satisfied.
6. **Build** — hand DESIGN.md to coding agents for consistent, on-brand UI output.

<!-- AI-CONTEXT-END -->

## The DESIGN.md Format

DESIGN.md is to visual design what AGENTS.md is to code behaviour — plain-text that LLMs read natively. A DESIGN.md file has **two layers**:

1. **YAML front matter** — Machine-readable design tokens (normative values), delimited by `---` fences at the top of the file.
2. **Markdown body** — Human-readable design rationale organised into `##` sections.

Tokens give agents exact values. Prose tells them *why* those values exist and how to apply them. The Google Labs spec is inspired by the [W3C Design Token Format (DTCG)](https://tr.designtokens.org/format/), so tokens round-trip to Figma variables, Tailwind theme configs, and `tokens.json`.

### YAML Front Matter Schema

```yaml
---
version: alpha              # optional, current format version
name: <string>              # required
description: <string>       # optional
colors:
  <token-name>: <Color>     # e.g. primary: "#1A1C1E"
typography:
  <token-name>: <Typography>
rounded:
  <scale-level>: <Dimension>
spacing:
  <scale-level>: <Dimension | number>
components:
  <component-name>:
    <token-name>: <string | number | token reference>
---
```

**Token types:**

| Type | Format | Example |
|------|--------|---------|
| Color | `#` + hex, sRGB | `"#1A1C1E"` |
| Dimension | number + unit (`px`, `em`, `rem`) | `48px`, `-0.02em` |
| Token Reference | `{path.to.token}` | `{colors.primary}` |
| Typography | object (see below) | *inline object* |

**Typography object:** `fontFamily`, `fontSize`, `fontWeight`, `lineHeight`, `letterSpacing`, `fontFeature`, `fontVariation`. `lineHeight` accepts a Dimension or a unitless multiplier. `fontWeight` accepts a bare number or quoted string.

**Token references** wrap a dotted path in curly braces: `{colors.primary-60}`, `{typography.body-md}`, `{rounded.sm}`. Components may reference composite tokens like `{typography.label-md}`; other groups must reference primitive values.

Component properties may also use bare numeric values where CSS/design systems commonly expect numbers, such as `fontWeight: 600` or `borderWidth: 1`. The upstream model handler stores these numbers as-is.

### Canonical Section Order

Sections use `##` headings. All are optional, but those present MUST appear in this order:

| # | Section | Aliases | aidevops tokens |
|---|---------|---------|-----------------|
| 1 | Overview | Brand & Style, Visual Theme | — |
| 2 | Colors | — | `colors:` |
| 3 | Typography | — | `typography:` |
| 4 | Layout | Layout & Spacing | `spacing:` |
| 5 | Elevation & Depth | Elevation | — |
| 6 | Shapes | — | `rounded:` |
| 7 | Components | — | `components:` |
| 8 | Do's and Don'ts | — | — |
| 9 | Responsive Behaviour | *(aidevops extension)* | — |
| 10 | Agent Prompt Guide | *(aidevops extension)* | — |

Sections 1-8 are the Google Labs spec. Sections 9-10 are aidevops-specific extensions the spec's unknown-content rule explicitly permits (unknown `##` headings are preserved, not errored). Duplicate section headings are an error — the linter rejects the file.

### Recommended Token Names (Non-Normative)

Adopted from the spec for cross-tool consistency:

- **Colors**: `primary`, `secondary`, `tertiary`, `neutral`, `background`, `surface`, `on-surface`, `error`, `outline`
- **Typography**: `headline-display`, `headline-lg`, `headline-md`, `body-lg`, `body-md`, `body-sm`, `label-lg`, `label-md`, `label-sm`
- **Rounded**: `none`, `sm`, `md`, `lg`, `xl`, `full`

### Component Property Tokens

Components map a name to a group of sub-token properties:

```yaml
components:
  button-primary:
    backgroundColor: "{colors.tertiary}"
    textColor: "{colors.on-tertiary}"
    typography: "{typography.label-md}"
    rounded: "{rounded.sm}"
    padding: 12px
  button-primary-hover:
    backgroundColor: "{colors.tertiary-container}"
```

Valid component properties: `backgroundColor`, `textColor`, `typography`, `rounded`, `padding`, `size`, `height`, `width`, `fontWeight`, `borderWidth`. Variants (hover, active, pressed, disabled) are expressed as **separate component entries with a related key name** — NOT nested under the base component.

### Unknown Content Behaviour

| Scenario | Spec behaviour |
|----------|---------------|
| Unknown section heading (e.g. our §9, §10) | Preserve; do not error |
| Unknown color/typography token name | Accept if value is valid |
| Unknown component property | Accept with warning |
| Duplicate section heading | **Error; reject the file** |

## Validation

The `@google/design.md` npm package ships four commands. Run the linter at least once before handing a DESIGN.md to a coding agent:

```bash
# Lint: eight rules, JSON output, exit 1 on errors
npx @google/design.md lint DESIGN.md

# Diff: detect token regressions between versions, including components
npx @google/design.md diff DESIGN.md DESIGN-v2.md

# Export: tokens to Tailwind theme config or DTCG tokens.json
npx @google/design.md export --format tailwind DESIGN.md > tailwind.theme.json
npx @google/design.md export --format dtcg DESIGN.md > tokens.json

# Spec: output the format spec (useful for injecting into agent prompts)
npx @google/design.md spec --rules
```

**Linter rules (eight, verified against `@google/design.md` v0.1.1):**

| Rule | Severity | What it checks |
|------|----------|---------------|
| `broken-ref` | error | Broken/circular token references and unknown component sub-tokens |
| `missing-primary` | warning | No `primary` color when other colors are defined |
| `contrast-ratio` | warning | Component `backgroundColor`/`textColor` pairs below WCAG AA (4.5:1) |
| `orphaned-tokens` | warning | Custom tokens defined but never referenced by any component; MD3 baseline families and siblings of referenced MD3 color tokens are exempt |
| `missing-typography` | warning | Colors defined but no typography tokens exist |
| `section-order` | warning | Sections out of canonical order |
| `missing-sections` | info | Optional sections (spacing, rounded) absent when others exist |
| `token-summary` | info | Count summary per token group |

**aidevops convention**: zero errors mandatory; warnings reviewed before committing. The aidevops library examples may carry missing-section or genuinely custom orphaned-token warnings while migration is in progress — see the library migration task.

## Creating a DESIGN.md

Choose method based on what exists:

| Situation | Method | Starting point |
|-----------|--------|---------------|
| New project, no design | Interview | Brand identity → palette → library match → template |
| Match existing website or brand links | Link extraction | `tools/design/design-md-from-links.md` |
| Styled report, HTML export, or PDF-ready output | Report presentation | `tools/design/report-presentation.md` |
| Known brand/style | Library copy | `tools/design/library/brands/` or `library/styles/` |
| `brand-identity.toon` exists | Brand identity | Map dimensions to sections (see below) |

**Method 1 (Interview):** Brand identity interview (`tools/design/brand-identity.md`) → select UI style from `ui-ux-catalogue.toon` → generate palette (`colour-palette.md`) → copy closest library example → synthesise into template → lint + preview + iterate.

**Method 2 (Links):** Dedicated link-to-DESIGN.md workflow extracts computed styles and brand patterns from user-provided website/branding links while treating external pages as untrusted content. Populate YAML token layer from extracted values, write prose rationale, check WCAG contrast/body text/focus/table/print readability, run `npx @google/design.md lint DESIGN.md`, generate preview, then hand off to build agents. Full workflow: `tools/design/design-md-from-links.md`.

**Method 2b (Reports):** For client reports, audits, dashboards, HTML exports, or PDF-ready output, map report components to DESIGN.md component tokens using `tools/design/report-presentation.md`. Cover/meta, TOC, chapter heroes, evidence badges, tactic cards, tables, source cards, callouts, checklists, and print CSS all need explicit token/component coverage.

**Method 3 (Library):** Copy closest `library/brands/` or `library/styles/` DESIGN.md into project root. Swap token values in YAML front matter, rewrite prose to match, update do's/don'ts. Lint + preview + iterate.

**Method 4 (Brand identity):** Map `context/brand-identity.toon` dimensions to sections using the canonical order:

- `visual_style` → §1 Overview, §5 Elevation, §6 Shapes
- `buttons_and_forms` → §7 Components (with YAML `components:` tokens)
- `voice_and_tone` + `copywriting_patterns` → §8 Do's and Don'ts
- `imagery` + `iconography` → §8 Do's and Don'ts
- `media_and_motion` → §7 Components, §9 Responsive
- `brand_positioning` → §1 Overview, §10 Agent Prompt Guide

## Using a DESIGN.md

**For coding agents:** Drop `DESIGN.md` in project root. Tell the agent: `"Build a landing page following DESIGN.md"`. The agent reads YAML tokens for exact values and prose for rationale — specific, reproducible output.

**For Tailwind projects:** Export tokens with `npx @google/design.md export --format tailwind DESIGN.md > tailwind.theme.json` and import into `tailwind.config.js`. Design updates in DESIGN.md propagate automatically on next build.

**For design review:** Generate `preview.html` from `tools/design/library/_template/preview.html.template`. Shows colour swatches, typography scale, button variants, card/input examples, spacing scale, light/dark modes.

**For screenshots:** Playwright at 1440px viewport, wait `networkidle`, capture PNG, convert to WebP (quality 90) and AVIF (quality 80). Repeat for dark mode. Respect screenshot size limits (max 1568px longest side).

## Library Structure

```text
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

**Migration status**: Pre-spec library files use the prose-only 9-section format without YAML front matter. The spec tolerates this (prose sections are preserved, missing tokens produce info/warning findings only). YAML-token migration is tracked as a separate backlog task.

## Format Version Policy

The spec format is `alpha` — expect changes. aidevops mitigations:

- **Pin the spec URL** in `## Related` so workers see the version they were built against.
- **Validate before commit** — `npx @google/design.md lint` catches most compatibility breaks.
- **YAML tokens are forward-safe** — they track the stable DTCG-inspired schema. Prose is free-form and survives format churn.
- **Component property set is the churn surface** — treat `size`, `height`, `width`, `fontWeight`, `borderWidth`, etc. as likely to evolve. Prefer composition (`{typography.label-md}`) over inline values where feasible, but bare numeric component values are valid when they express unitless design intent.

## Related

- `tools/design/brand-identity.md` -- Strategic brand profile (upstream input)
- `tools/design/ui-ux-inspiration.md` -- URL study discovery and inspiration workflow
- `tools/design/design-md-from-links.md` -- Dedicated website/brand links to DESIGN.md workflow
- `tools/design/report-presentation.md` -- Report components, HTML/PDF styling, and print-ready guidance
- `tools/design/design-inspiration.md` -- 60+ curated gallery resources
- `tools/design/colour-palette.md` -- Palette generation and spinning
- `tools/design/library/README.md` -- Library index and usage
- `tools/design/ui-ux-catalogue.toon` -- 36+ UI style patterns
- `product/ui-design.md` -- Product design standards and accessibility
- `tools/ui/ui-skills.md` -- Opinionated UI build constraints
- `tools/ui/nothing-design-skill.md` -- Example: complete design system as agent
- `templates/DESIGN.md.template` -- Skeleton for `aidevops init`
- `workflows/ui-verification.md` -- Visual regression testing
- **External**: [google-labs-code/design.md](https://github.com/google-labs-code/design.md) — normative spec, CLI, examples
- **External**: [W3C Design Tokens Format Module](https://tr.designtokens.org/format/) — underlying token schema inspiration
