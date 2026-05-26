<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Brand Style Guide

::: report-cover
**IBM-inspired brand guide for usable report and content production.** This specimen is a practical show-and-tell library: brand assets, colour roles, typography, badges, message states, data components, recommendations, briefs, and export rules.

IBM-styled content should feel **systematic, engineered, accessible, and explicit**. Use the grid to make complex information understandable; use blue to mark interaction and verified structure; use red, amber, and green only when the status itself matters.
:::

::: manifest-card

### IBM production manifest

- Brand: IBM
- Content system: technical reports, governance memos, product explainers, audit handoffs
- Shape language: modular grid, square panels, strong alignment, visible rules
- Colour rule: blue is the system accent; severity colours are functional, not decorative
- Writing rule: classify evidence, name the decision, then show the verification path
- Export rule: every public artefact uses placeholder evidence and hides browser PDF chrome
:::

## 1. Brand assets and surface rules

::: brand-asset-grid
::: brand-asset-card accent=light

### Logo on light surface

Show primary artwork on white or cool-grey backgrounds with generous clearspace. **Use for:** report covers, section openers, and client handoff PDFs.
:::

::: brand-asset-card accent=dark

### Logo on dark surface

Use reverse artwork only when the whole page or module is dark. *Do not mix light and dark logo treatments in the same component row.*
:::

::: brand-asset-card accent=light

### Icon or monogram

Use a compact mark for small metadata blocks, export thumbnails, or dashboard tiles. Keep the mark visually centred and never use it as a bullet.
:::

::: brand-asset-card accent=dark

### Partner lockup

Use a lockup area when the brand appears beside a product, client, or programme name. Keep equal optical weight and align baselines.
:::
:::

::: brand-swatch-grid
::: swatch-card accent=blue

### Primary blue

Use for links, active states, chart bars, focus indicators, and primary system emphasis. Pair with white or very light grey.
:::

::: swatch-card accent=ink

### Strong text

Use for headings, dense tables, labels, and decision statements. It carries authority without needing extra decoration.
:::

::: swatch-card accent=raised

### Raised surface

Use for cards, tables, briefs, and source ledgers. It should separate information without creating unrelated widths.
:::

::: swatch-card accent=red

### Critical state

Use only for blockers, risk, failed validation, or policy exceptions. Always pair it with a text label and recovery instruction.
:::

::: swatch-card accent=amber

### Warning state

Use for dependencies, partial evidence, or pending verification. It should be visible in print, not a faint tint.
:::

::: swatch-card accent=green

### Verified state

Use for shipped controls, passed checks, and preserved patterns. Keep the label legible on the state colour.
:::
:::

## 2. Typography and formatting

::: brand-type-scale
::: type-specimen

### H1 / cover title

**Technical audit readiness report**

Use for the single page purpose. Keep it direct; avoid marketing flourish.
:::

::: type-specimen

### H2 / section title

**Evidence and decision path**

Use H2s for major production tasks: assets, colours, data, decisions, export.
:::

::: type-specimen

### H3 / component title

**Source ledger card**

Use H3s inside reusable blocks. They should name the component, not repeat the section.
:::

::: type-specimen

### Body, emphasis, and citation

Normal body copy states the fact. **Bold** marks the decision or required field. *Italic* marks caveat, interpretation, or non-blocking nuance.
:::
:::

::: quote-card
Use quotation styling for source excerpts and reviewer notes. A quote is not a notification; it is a cited voice that supports or challenges the report claim.
:::

## 3. Information tagging badges

Badges are **metadata tags**, not notifications. Use them inline beside claims, table cells, or source IDs to classify evidence without taking over the page.

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}} {{badge:critical}} {{badge:high}} {{badge:medium}} {{badge:low}}
:::

::: facts-table-wrap

| Badge | Purpose | Use example | Avoid |
|---|---|---|---|
| Verified | Confirmed evidence | “Pricing table present in first-fetch HTML” | Using it for assumptions |
| Partial | Some support, not enough | “Two engines cite the page; one cites stale copy” | Hiding uncertainty |
| Inferred | Modelled judgement | “Likely entity mismatch from source drift” | Presenting as fact |
| Missing | No evidence found | “No source card for the claim” | Using as blame language |

:::

## 4. Message states and notifications

Notifications are interruption patterns. They need colour, shape, label, purpose, and action. They are not badge rows.

::: notification-grid
::: info-panel severity=critical

### Critical blocker

**Purpose:** stop delivery until fixed. Use when evidence is inaccessible, a required source is missing, or a public artefact risks disclosure.

*Example:* “Source B004 is absent from the export ledger. Add it before approval.”
:::
::: info-panel severity=high

### Warning dependency

**Purpose:** expose risk without blocking every reader. Use for partial evidence, ownership gaps, or pending validation.

*Example:* “Table fit passes A4 but needs slide review before client deck export.”
:::
::: info-panel severity=medium

### Information note

**Purpose:** explain method or scope. Use for assumptions, sampling windows, and environment details.

*Example:* “Crawler evidence was captured from a logged-out first fetch.”
:::
::: info-panel severity=low

### Verified outcome

**Purpose:** mark a stable pattern to preserve. Use when a check passed and should not regress.

*Example:* “All priority cards now include owner, source, and verification fields.”
:::
:::

## 5. Report component show-and-tell

::: stats-strip
::: kpi-card
**12**

Component families covered. **Source:** B001.
:::
::: kpi-card
**4**

State colours with visible contrast. **Source:** B002.
:::
::: kpi-card
**100%**

Recommendation cards include owner and verification. **Source:** B003.
:::
::: kpi-card
**0**

Private artefacts in public output. **Source:** B004.
:::
:::

::: visibility-bars
Component coverage — 100%

Evidence traceability — 92%

Notification clarity — 88%

Print readiness — 94%
:::

::: facts-table-wrap

| Component | Purpose | IBM treatment | Example content |
|---|---|---|---|
| Manifest | Scope and production rules | Field grid with firm labels | “Export rule: placeholder evidence only” |
| KPI card | Executive metric | Large value, short source line | “12 component families covered” |
| Facts table | Dense comparison | Aligned headers, stable columns | Component / purpose / treatment / example |
| Source ledger | Claim provenance | One width, row dividers, source IDs | B001 — Component inventory |
| Brief card | Delivery handoff | Light command panel, blue left rule | Task / files / acceptance / verification |

:::

::: ledger-list
B001 — Component inventory — **High confidence**; checks rendered block families.

B002 — Severity review — **High confidence**; validates visible critical, warning, information, and verified states.

B003 — Recommendation audit — **Medium confidence**; verifies owner, due date, source, and acceptance fields.

B004 — Redaction audit — **High confidence**; confirms public-safe export.
:::

## 6. Recommendation patterns

::: priority-card priority=critical

### Critical control gap

Use when a missing component, evidence field, or verification step blocks approval. {{evidence:verified}}

**Owner:** Governance. **Due:** current release. **Verify:** source ledger contains B001 and B004.
:::

::: priority-card priority=high

### High-priority dependency

Use when a recommendation depends on another system, owner, or evidence source. {{evidence:partial}}

**Owner:** Delivery. **Due:** next sprint. **Verify:** dependency has an assigned owner.
:::

::: priority-card priority=medium

### Medium optimisation

Use when the report is correct but can improve scanability, table density, or export fidelity. {{evidence:inferred}}

**Owner:** Design systems. **Due:** backlog. **Verify:** A4 and slide output remain aligned.
:::

::: priority-card status=done

### Completed control

Use for implemented safeguards and stable patterns. {{evidence:verified}}

**Owner:** QA. **Verified:** B004. **Preserve:** state label remains high contrast.
:::

::: good-bad
::: good-row

### Preserve

- **Explicit source IDs** beside claims.
- Stable table columns and aligned panel widths.
- Clear owner, due date, and verification fields.
:::
::: bad-row

### Avoid

- Ambiguous status labels.
- Decorative charts without data labels.
- Recommendations without acceptance criteria.
:::
:::

## 7. Handoff, code, and export

::: brief-card

### Implementation brief

**Task:** Apply IBM-styled report components to a technical audit.

**Files:** report Markdown, renderer CSS, evidence ledger, PDF exports.

**Acceptance:** every finding maps to source IDs, confidence, owner, and verification.

**Verification:** render HTML, A4, US Letter, and slides; inspect badges, notifications, charts, tables, and code panels.
:::

::: example-card title="IBM light code panel"

```text
Do: classify evidence, assign owner, include verification.
Do not: use a notification when a small metadata badge is enough.
```

:::

::: source-card

### Source-card purpose

Use source cards as governance records: source ID, type, observed date, claim supported, confidence, sensitivity, and storage location.
:::

::: privacy-note
**Public artifact rule**

IBM-styled public examples must not include private client names, URLs, local paths, screenshots, raw exports, or uncontrolled evidence excerpts.
:::

::: version-summary
IBM brand style guide specimen · usable production guide · public-safe placeholder content
:::
