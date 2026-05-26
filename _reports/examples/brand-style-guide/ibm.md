<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# IBM Brand Style Guide

::: report-cover
**IBM-inspired report presentation guide.** Use this specimen to see how IBM-styled reports present report components for evidence, governance, implementation, and executive decision-making.

IBM styling is structured, modular, technical, and explicit. The report should feel like a trustworthy system: clear grids, precise labels, accessible contrast, and rigorous component states.
:::

::: manifest-card

### IBM style manifest

- Brand: IBM
- Report mode: structured enterprise evidence report
- Shape language: modular grid, clear rules, restrained surfaces
- Primary accent: IBM blue
- Evidence grammar: explicit labels, source IDs, confidence and status
- Best use: technical audits, architecture reports, governance, compliance
:::

## 1. Foundation tokens

::: brand-swatch-grid
::: specimen-card

### Neutral canvas

Use white and cool greys to create a stable enterprise workspace. Purpose: make complex information feel orderly.
:::

::: specimen-card

### Blue system accent

Use blue for active states, links, selected navigation, and information emphasis. Purpose: signal system action and trust.
:::

::: specimen-card

### Rule-based structure

Use visible grid lines, table rules, and panel boundaries. Purpose: classification and comparison stay clear.
:::

::: specimen-card

### Status palette

Use accessible red, amber, blue, and green states with text labels. Purpose: enterprise reports must remain understandable in grayscale and print.
:::
:::

::: brand-type-scale
::: specimen-card

### Display hierarchy

Use clear sans-serif headings with systematic scale. Purpose: let structure, not ornament, carry authority.
:::

::: specimen-card

### Body copy

Use direct sentences, strong labels, and predictable spacing. Purpose: technical readers can scan quickly.
:::

::: specimen-card

### Code and metadata

Use mono for IDs, commands, source keys, and implementation references. Purpose: operational evidence remains precise.
:::

::: specimen-card

### Tables

Tables are first-class IBM components. Purpose: enterprise decisions often depend on stable rows, columns, and comparison logic.
:::
:::

## 2. Report element index

::: toc-list
01 — Foundations — tokens, type, grid, status

02 — Notifications — severity, information, evidence, action

03 — Data — KPI cards, tables, bars, ledgers

04 — Recommendations — priority cards, brief, checklist

05 — Governance — source cards, code, privacy
:::

::: action-line
**Design rule:** classify the evidence, state the decision, and show the verification path.
:::

## 3. Notification variations

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}} {{badge:critical}} {{badge:high}} {{badge:medium}} {{badge:low}}
:::

::: severity-key
::: info-panel severity=critical

### Critical system state

Use for blockers, policy violations, inaccessible data, or missing verification. Shape: modular panel with explicit severity label.
:::
::: info-panel severity=high

### Warning system state

Use for partial evidence, high-risk assumptions, or implementation dependencies. Include owner and next check.
:::
::: info-panel severity=medium

### Information system state

Use for method details, background, or architectural context. Keep it precise.
:::
::: info-panel severity=low

### Verified system state

Use for completed controls, verified evidence, and stable patterns. Include source and date.
:::
:::

::: evidence-panel severity=medium

### Evidence panel

Evidence panels explain source strength, confidence, and the claim supported. They should never mix facts with recommendations.
:::

::: action-panel severity=high

### Action panel

Action panels convert evidence into owner, due date, acceptance criteria, and verification steps.
:::

## 4. Data block examples

::: stats-strip
::: kpi-card
**12**

Components covered in this specimen. Source: B001.
:::
::: kpi-card
**4**

Severity states documented and labelled. Source: B002.
:::
::: kpi-card
**100%**

Tables include stable headers and row labels. Source: B003.
:::
::: kpi-card
**0**

Unredacted private artifacts in the export. Source: B004.
:::
:::

::: facts-table-wrap

| Component | Purpose | IBM treatment | Verification |
|---|---|---|---|
| Manifest | Scope and governance | Field grid with precise labels | All fields are present |
| Notification | System status | Label plus state colour | Meaning survives grayscale |
| Facts table | Dense comparison | Stable headers and rules | Columns fit print profile |
| Brief | Delivery control | Task, files, acceptance, verify | Worker can execute |

:::

::: visibility-bars
Component coverage — 100%

Evidence traceability — 92%

Notification clarity — 88%

Print readiness — 94%
:::

::: ledger-list
B001 — Component inventory — High confidence; checks all rendered block families.

B002 — Severity review — High confidence; validates critical, high, medium, low states.

B003 — Table audit — High confidence; verifies headers, wrapping, and print fit.

B004 — Redaction audit — High confidence; confirms public-safe export.
:::

## 5. Recommendation and governance examples

::: priority-card priority=critical

### Critical control gap

Use when a missing component, evidence field, or verification step blocks report approval. {{evidence:verified}}

Owner: Governance. Due: Current release. Source: B001.
:::

::: priority-card priority=high

### High-priority dependency

Use when a recommendation depends on another system, owner, or evidence source. {{evidence:partial}}

Owner: Delivery. Due: Next sprint. Source: B002.
:::

::: priority-card priority=medium

### Medium optimisation

Use when the report is correct but can improve scanability, table density, or export fidelity. {{evidence:inferred}}

Owner: Design systems. Due: Backlog. Source: B003.
:::

::: priority-card status=done

### Completed control

Use for verified safeguards and implemented patterns. {{evidence:verified}}

Owner: QA. Verified: B004.
:::

::: good-bad
::: good-row

### Preserve

- Explicit source IDs.
- Stable table columns.
- Clear owner and verification fields.
:::
::: bad-row

### Avoid

- Ambiguous status labels.
- Decorative charts without data labels.
- Recommendations without acceptance criteria.
:::
:::

::: brief-card

### Implementation brief

**Task:** Apply IBM-styled report components to a technical audit.

**Files:** report Markdown, renderer CSS, evidence ledger, PDF exports.

**Acceptance:** every finding maps to source IDs, confidence, owner, and verification.

**Verification:** run renderer validation, markdown lint, print export, and evidence-link review.
:::

::: checklist-card

- [x] Manifest states scope, owner, and redaction level.
- [x] Tables include clear headers and evidence columns.
- [ ] Every priority card has acceptance criteria.
- [ ] Source cards link to redacted evidence stubs or secure storage notes.
:::

## 6. Code, source, and privacy examples

::: example-card title="IBM-styled verification command"

```text
Validate: renderer source -> HTML -> A4 PDF -> source ledger -> owner checklist
Pass: every recommendation has evidence, owner, due date, acceptance, verification
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
IBM brand style guide specimen · comprehensive report component coverage · public-safe placeholder content
:::
