<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Brand Style Guide Report

::: report-cover
**A report format for presenting DESIGN.md brand systems.** This example turns brand tokens, component rules, and usage constraints into a client-readable style-guide dossier.

Use this when a brand library needs to be reviewed by humans and reused by report agents. The report should be generated from `DESIGN.md` plus chapter files, not from memory.
:::

::: manifest-card

### Style-guide manifest

- Source library: `.agents/tools/design/library/brands`
- Example brands: Signal Agency, Apple, IBM, Bento, Times
- Purpose: show token coverage, component grammar, constraints, and report usage
- Export profiles: HTML, A4, US Letter, Slides
- Rule: public examples use brand names only; client evidence remains redacted
:::

## How to read this guide

Brand style guides need more than colours and fonts. A report-ready brand package should include visual theme, colour roles, typography, component grammar, layout, elevation, do/don't rules, responsive behaviour, and an agent prompt guide.

::: toc-list
§ 01 | Token inventory | Colour, type, spacing, radii

§ 02 | Component grammar | Cards, tables, badges, source ledgers, briefs

§ 03 | Brand examples | Signal, Apple, IBM, Bento, Times

§ 04 | Agent handoff | Reproduction rules and validation
:::

## Token inventory

::: brand-swatch-grid
::: specimen-card

### Signal Agency — paper and ink

`background #ECEEEB` · warm paper for report pages.

`on-surface #0B0D0A` · near-black ink for text, rules, and dossier headers.

Usage: use rule weight and surface changes before adding decoration.
:::

::: specimen-card

### Signal Agency — terracotta signal

`primary #B93A19` · use for critical decisions, P0 emphasis, cover italic, and small glyphs.

Constraint: never flood large areas with the accent; it is a signal, not a background.
:::

::: specimen-card

### Apple — quiet surfaces

Use restrained neutrals, large whitespace, and product-like hierarchy. Components should feel polished and calm rather than editorial or dossier-like.
:::

::: specimen-card

### IBM — structured enterprise

Use crisp grids, clear data tables, modular panels, and neutral surfaces. Components should privilege legibility, classification, and enterprise evidence.
:::
:::

::: brand-type-scale
::: specimen-card

### Display type

Large report titles should preserve brand personality. Signal uses condensed Bricolage Grotesque with tight tracking; Times uses newspaper-like editorial serif; IBM uses more systematic enterprise typography.
:::

::: specimen-card

### Body type

Body copy should stay readable in HTML and PDF. Keep 56-64ch lines, avoid overusing uppercase, and verify print output after font substitution.
:::

::: specimen-card

### Mono metadata

Use mono labels for source IDs, dates, engine names, priorities, and run IDs. This makes evidence provenance scannable without becoming decorative.
:::

::: specimen-card

### Code and examples

Code blocks inherit each brand's code surface. Signal stays light; developer-dark styles may invert; all production examples need accessible contrast.
:::
:::

## Component grammar

::: brand-component-grid
::: specimen-card

### Cover and manifest

The cover sets mood; the manifest proves scope. Include prepared-for, period, source count, version, confidentiality, and next review date.
:::

::: specimen-card

### KPI cards and stats strips

Use large numerals only for metrics with a period/window and source ID. Avoid unsupported “AI share of voice” claims unless per-engine lines prove them.
:::

::: specimen-card

### Tables and source ledgers

Tables carry findings; source ledgers carry trust. Use stable columns, evidence badges, confidence labels, and redacted storage notes.
:::

::: specimen-card

### Priority cards and briefs

Priority cards are executive-readable; implementation briefs are worker-readable. Each needs owner, due date, source IDs, and verification.
:::
:::

## Brand examples

::: dossier-card

### Signal Agency

Research-dossier style: warm paper, black rules, terracotta signal, square cards, mono evidence labels, source-led report grammar, and light code blocks. Best for AI-search audit reports, client evidence packs, and editorial strategy documents.
:::

::: dossier-card

### Apple

Premium product style: reduced chrome, generous spacing, calm hierarchy, elegant typography, and minimal visible borders. Best for executive summaries, product narratives, and polished client-facing recommendations.
:::

::: dossier-card

### IBM

Enterprise systems style: structured grids, explicit categories, accessible contrast, and utilitarian components. Best for technical audits, governance, architecture, and compliance reports.
:::

::: dossier-card

### Bento

Modular showcase style: card-based blocks, friendly surface contrast, and concise grouped information. Best for capability overviews and feature-led reports.
:::

::: dossier-card

### Times

Editorial newspaper style: rule-based hierarchy, serif tone, print-first feel, and restrained emphasis. Best for research digests, competitive narratives, and long-form findings.
:::

## Agent handoff

::: checklist-card

- [x] Start from `DESIGN.md` front matter and chapter files.
- [x] Verify colour, typography, component, layout, elevation, responsive, and prompt-guide coverage.
- [ ] Generate a brand-style-guide report before using a new brand in client reports.
- [ ] Render HTML and print profiles; inspect tables, badges, code blocks, and TOC.
- [ ] Keep public examples free of private client names, URLs, local paths, screenshots, and raw evidence.
:::

::: brief-card

### Brand extraction brief

**Task:** Convert a source style guide into a complete DESIGN.md brand library and report preview.

**Files:** `DESIGN.md`, chapter files, report renderer style, brand-style-guide example.

**Acceptance:** tokens cover colour/type/spacing/radii; components cover cover, cards, tables, badges, ledgers, briefs, checklists; print export has no browser chrome.

**Verification:** DESIGN.md lint, renderer validate, HTML preview, A4/Letter/slides export, and visual review against source specimen.
:::

::: version-summary
Brand style-guide report example · generated from aidevops DESIGN.md library patterns · public-safe placeholder content
:::
