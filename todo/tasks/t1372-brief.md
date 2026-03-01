# t1372: Create UI/UX inspiration skill entry point + brand identity interview workflow

## Origin

- **Created:** 2026-03-01
- **Session:** claude-code:interactive
- **Created by:** marcus (human, ai-interactive)
- **Parent task:** none (sibling of t1371, t1373)
- **Conversation context:** Part of the UI/UX inspiration skill build. User wants: (1) a skill that agents read when doing design work, (2) a workflow for studying URLs and extracting design patterns, (3) an interview process for new/rebranding projects where the agent shows example sites and asks the user to share sites they like before beginning design work.

## What

Create `.agents/tools/design/ui-ux-inspiration.md` — the skill entry point that tells agents how to use the design catalogue, study URLs, extract patterns, interview users on style preferences, and apply brand identity to design decisions.

Key sections:

1. **Quick Reference** — when to read this skill, what it provides, relationship to other design/content files
2. **Design Workflow** — step-by-step: check brand identity -> consult catalogue -> check inspiration entries -> apply ui-verification.md quality gates
3. **Brand Identity Interview** — structured interview workflow for new/rebranding projects:
   - Present curated example links from different style categories (3-5 per category: minimal, bold, playful, premium, technical, editorial)
   - Ask user to share URLs of sites/apps they already like
   - For each URL: extract colour palette, typography, layout patterns, button/form styling, iconography style, imagery approach, copy tone
   - Synthesise findings into a draft brand identity (feeds into t1373's brand-identity.md template)
   - Confirm with user before proceeding
4. **URL Study Workflow** — how to analyse a URL and extract design patterns:
   - Fetch via Playwright (full render needed for CSS computed styles)
   - Screenshot at 3 breakpoints (mobile 375px, tablet 768px, desktop 1440px)
   - Extract: CSS custom properties, computed font stacks, colour usage, spacing scale, border-radius patterns, button styles, form field styles, icon library detection, image treatment (photography vs illustration, filters, aspect ratios)
   - Also extract: copy tone (formal/casual, sentence length, vocabulary level, use of humour, CTA language), imagery style (photography/illustration/3D/abstract, mood, subjects), iconography (outline/filled/duotone, library, sizing)
   - Write structured entry to inspiration section of ui-ux-catalogue.toon
5. **Bulk URL Import** — workflow for processing a bookmarks folder or URL list:
   - Accept: plain URL list (one per line), HTML bookmarks export, or comma-separated
   - Process each URL through the study workflow
   - Generate summary report: common patterns across all URLs, style convergence, recommended catalogue styles that match
6. **Buttons & Forms Focus** — specific guidance on extracting and applying button/form styling:
   - Button variants: primary, secondary, ghost, destructive, icon-only
   - Form elements: input fields, selects, textareas, checkboxes, radios, toggles, date pickers
   - States: default, hover, focus, active, disabled, error, success, loading
   - Patterns: border-radius consistency, padding scale, transition timing, focus ring style

## Why

- No existing aidevops skill bridges "I like this site's design" to "here's how to replicate that feel"
- The interview workflow prevents the common failure mode of starting design work without understanding the user's aesthetic preferences
- Bulk URL import enables building a personal design library over time from accumulated bookmarks
- Buttons and forms are where users interact most — inconsistent interactive element styling is the most visible design flaw

## How (Approach)

1. Create `.agents/tools/design/ui-ux-inspiration.md` with YAML frontmatter (mode: subagent, tools: read, bash, webfetch, task)
2. The interview workflow uses a structured prompt sequence — not a script, but guidance for the agent on what to ask and in what order
3. Example links in the interview section should be drawn from `.agents/tools/design/design-inspiration.md` resource URLs (Godly, Awwwards, etc.) — curated to show distinct style categories
4. The URL study workflow uses Playwright for full-render extraction (not webfetch — needs computed CSS)
5. Reference `ui-ux-catalogue.toon` for catalogue lookups, `workflows/ui-verification.md` for quality gates, `tools/design/brand-identity.md` (t1373) for brand identity template
6. Include 15-20 curated example URLs across style categories for the interview workflow (select from sites that are stable, well-known, and represent distinct design approaches)

Key files:
- `.agents/tools/design/ui-ux-inspiration.md` — new file (primary deliverable)
- `.agents/tools/design/ui-ux-catalogue.toon` — referenced (created by t1371)
- `.agents/tools/design/design-inspiration.md` — existing resource directory (example URLs drawn from here)
- `.agents/tools/design/brand-identity.md` — referenced (created by t1373)
- `.agents/workflows/ui-verification.md` — quality gates (referenced)
- `.agents/tools/browser/playwright.md` — Playwright usage for URL study

## Acceptance Criteria

- [ ] Skill file exists at `.agents/tools/design/ui-ux-inspiration.md` with valid YAML frontmatter
  ```yaml
  verify:
    method: codebase
    pattern: "^---"
    path: ".agents/tools/design/ui-ux-inspiration.md"
  ```
- [ ] Contains Brand Identity Interview section with structured question sequence
  ```yaml
  verify:
    method: codebase
    pattern: "Brand Identity Interview|Style Interview|Design Interview"
    path: ".agents/tools/design/ui-ux-inspiration.md"
  ```
- [ ] Contains 15+ curated example URLs across 4+ distinct style categories
  ```yaml
  verify:
    method: bash
    run: "rg 'https?://' .agents/tools/design/ui-ux-inspiration.md | wc -l | awk '$1 >= 15'"
  ```
- [ ] Contains URL Study Workflow section with extraction steps for: colours, typography, layout, buttons, forms, iconography, imagery, copy tone
  ```yaml
  verify:
    method: codebase
    pattern: "URL Study|Site Analysis|Design Extraction"
    path: ".agents/tools/design/ui-ux-inspiration.md"
  ```
- [ ] Contains Bulk URL Import section accepting plain URL lists and bookmarks exports
- [ ] Contains Buttons & Forms section covering all interactive element states
- [ ] References (not duplicates) ui-verification.md, ui-ux-catalogue.toon, brand-identity.md, design-inspiration.md
  ```yaml
  verify:
    method: codebase
    pattern: "ui-verification\\.md|ui-ux-catalogue\\.toon|brand-identity\\.md|design-inspiration\\.md"
    path: ".agents/tools/design/ui-ux-inspiration.md"
  ```
- [ ] No hardcoded client-specific content (must be project-agnostic)
- [ ] Lint clean (markdown-formatter)

## Context & Decisions

- **Interview before implementation**: User explicitly requested that new/rebranding projects start with a style interview. The agent should never begin design work without understanding preferences.
- **Playwright over webfetch**: URL study needs computed CSS values (actual colours, font stacks, spacing) which requires full browser rendering. webfetch returns HTML source only.
- **Example URLs curated, not generated**: The interview presents real, stable sites as style examples. These are hand-picked from design-inspiration.md resources, not AI-generated URLs (which would 404).
- **Copy tone extraction**: User specifically noted that brand character comes from copywriting style, imagery, iconography, and media — not just visual design. The URL study must extract verbal identity alongside visual.
- **Buttons and forms**: User specifically requested these. They're the primary interaction surface and the most visible indicator of design consistency.

## Relevant Files

- `.agents/tools/design/ui-ux-inspiration.md` — new file to create
- `.agents/tools/design/ui-ux-catalogue.toon` — catalogue data (t1371)
- `.agents/tools/design/design-inspiration.md` — existing resource URLs
- `.agents/tools/design/brand-identity.md` — brand identity template (t1373)
- `.agents/workflows/ui-verification.md:244-309` — design quality gates
- `.agents/tools/browser/playwright.md` — Playwright reference for URL study
- `.agents/content/guidelines.md` — existing copywriting guidelines (referenced for tone extraction)

## Dependencies

- **Blocked by:** t1371 (catalogue TOON must exist to reference), t1373 (brand identity template must exist to reference)
- **Blocks:** nothing directly (but enables the full design workflow)
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Review design-inspiration.md, select example URLs, review Playwright extraction patterns |
| Implementation | 2h | Write skill entry point with all sections |
| Testing | 30m | Verify references resolve, example URLs are live, markdown lint |
| **Total** | **3h** | |
