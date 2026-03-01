# t1371: Create UI/UX catalogue TOON file

## Origin

- **Created:** 2026-03-01
- **Session:** claude-code:interactive
- **Created by:** marcus (human, ai-interactive)
- **Conversation context:** User evaluated nextlevelbuilder/ui-ux-pro-max-skill (36k stars, MIT) for ingestion. Decided against direct dependency but identified the CSV data (styles, palettes, typography, industry patterns, UX guidelines) as a valuable seed dataset for a custom aidevops skill. TOON format chosen over markdown for structured catalogue data.

## What

Create `.agents/tools/design/ui-ux-catalogue.toon` containing structured design knowledge seeded from the upstream repo's CSV data, converted to TOON format. The file serves as a searchable reference catalogue that agents read directly (no Python search engine, no external dependencies).

Sections:

1. **`styles`** — 67 UI styles (Glassmorphism, Brutalism, Neumorphism, Bento Grid, etc.) with: keywords, primary/secondary colours, effects, best-for/not-for, accessibility rating, performance rating, mobile-friendly rating, framework compatibility, CSS keywords, implementation checklist, design system variables
2. **`palettes`** — 96 industry-mapped colour palettes with: product type, primary/secondary/CTA/background/text/border hex values, usage notes
3. **`typography`** — 57 font pairings with: category, heading/body fonts, mood keywords, best-for, Google Fonts URL, CSS import, Tailwind config
4. **`industry_patterns`** — 100 reasoning rules mapping: UI category -> recommended pattern, style priority, colour mood, typography mood, key effects, decision rules (JSON conditions), anti-patterns, severity
5. **`buttons_and_forms`** — Button styles (primary/secondary/ghost/destructive), form field patterns (input, select, textarea, checkbox, radio, toggle), validation states, loading states, disabled states. Mapped to the 67 UI styles so each style has consistent interactive element guidance.
6. **`inspiration`** — Empty section with template structure for user-added entries. Each entry: URL, site name, extracted patterns (layout, colour, typography, iconography, imagery, copy tone, button/form style), widgets worth reusing, when to use, when not to use.

## Why

- LLMs default to generic "blue SaaS" designs without structured reference data
- The upstream repo proved this data improves design output (36k stars)
- Having it in TOON means zero runtime dependencies (no Python, no API, no premium subscription)
- The catalogue + inspiration pattern lets users build a custom design library over time
- Buttons and forms are the most-touched interactive elements and need style-consistent guidance per UI style

## How (Approach)

1. Fetch CSV files from `gh api repos/nextlevelbuilder/ui-ux-pro-max-skill/contents/src/ui-ux-pro-max/data/` (already explored in conversation)
2. Parse each CSV and convert to TOON sections using the `<!--TOON:section[count]{fields}: ... -->` format
3. For `buttons_and_forms`: synthesise from the existing style data (each style's CSS keywords, design system variables, and implementation checklist contain button/form guidance) plus standard patterns from Apple HIG, Material Design 3, and our own `workflows/ui-verification.md` interaction principles
4. For `inspiration`: create empty section with template showing the expected entry format
5. Keep total file size under 250KB to remain within comfortable context window limits
6. If data exceeds 250KB, split into `ui-ux-catalogue.toon` (styles + palettes + typography + buttons_and_forms) and `ui-ux-industry-patterns.toon` (industry_patterns + inspiration)

Key files:
- `.agents/tools/design/ui-ux-catalogue.toon` — new file (primary deliverable)
- `.agents/tools/design/design-inspiration.md` — existing, unchanged (complementary "where to look" resource)
- `.agents/workflows/ui-verification.md:244-309` — existing design principles checklist (referenced, not duplicated)

## Acceptance Criteria

- [ ] TOON file parses correctly (valid TOON syntax, all sections have correct field counts)
  ```yaml
  verify:
    method: bash
    run: "bun run ~/.aidevops/agents/scripts/toon-helper.ts decode .agents/tools/design/ui-ux-catalogue.toon 2>&1 | grep -v error"
  ```
- [ ] Contains all 6 sections: styles, palettes, typography, industry_patterns, buttons_and_forms, inspiration
  ```yaml
  verify:
    method: codebase
    pattern: "TOON:(styles|palettes|typography|industry_patterns|buttons_and_forms|inspiration)"
    path: ".agents/tools/design/ui-ux-catalogue.toon"
  ```
- [ ] styles section has 67+ entries with fields: name, type, keywords, primary_colors, effects, best_for, not_for, accessibility, performance, mobile, css_keywords
  ```yaml
  verify:
    method: bash
    run: "rg 'TOON:styles\\[' .agents/tools/design/ui-ux-catalogue.toon | grep -oE '\\[([0-9]+)\\]' | grep -oE '[0-9]+' | awk '$1 >= 67'"
  ```
- [ ] palettes section has 96+ entries
- [ ] typography section has 57+ entries with Google Fonts URLs
- [ ] industry_patterns section has 100+ entries
- [ ] buttons_and_forms section covers: primary, secondary, ghost, destructive button variants + input, select, textarea, checkbox, radio, toggle form elements
- [ ] inspiration section has empty template with documented entry format
- [ ] File size under 250KB
  ```yaml
  verify:
    method: bash
    run: "test $(wc -c < .agents/tools/design/ui-ux-catalogue.toon) -lt 256000"
  ```
- [ ] No duplication of content from `workflows/ui-verification.md` — references only
- [ ] Lint clean (shellcheck N/A, markdown-formatter on any .md changes)

## Context & Decisions

- **TOON over markdown**: Structured tabular data (67 styles x 20+ fields) is better represented in TOON than markdown tables. TOON is also more token-efficient for LLM consumption.
- **No Python search engine**: The upstream repo uses BM25 over CSVs. We skip this because the LLM can read the TOON directly and reason over it better than keyword matching. Zero dependencies.
- **No premium API dependency**: The upstream premium product (uupm.cc) wraps the same data as a hosted MCP API. We use the MIT-licensed local data only.
- **Buttons and forms added**: Not in upstream data. User specifically requested these as they're the most-touched interactive elements.
- **Inspiration section starts empty**: Will be populated by t1372's URL study workflow.

## Relevant Files

- `.agents/tools/design/ui-ux-catalogue.toon` — new file to create
- `.agents/tools/design/design-inspiration.md` — existing resource directory (complementary)
- `.agents/workflows/ui-verification.md:244-309` — our design quality gates (reference)
- `.agents/mobile-app-dev/ui-design.md` — mobile design standards (reference)
- `.agents/subagent-index.toon` — TOON format reference

## Dependencies

- **Blocked by:** nothing
- **Blocks:** t1372 (skill entry point references the catalogue), t1373 (brand identity references catalogue for style selection)
- **External:** GitHub API access to fetch upstream CSVs (public repo, no auth needed)

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Fetch and review all upstream CSVs |
| Implementation | 3h | Convert CSVs to TOON, synthesise buttons_and_forms section |
| Testing | 30m | Validate TOON parsing, field counts, file size |
| **Total** | **4h** | |
