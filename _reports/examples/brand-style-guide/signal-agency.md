<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Signal Agency Brand Style Guide

::: report-cover
**Signal Agency report presentation guide.** Use this specimen to see how Signal Agency styles every report element: evidence, data, action, risk, source provenance, and implementation handoff.

Signal Agency is warm-paper editorial dossier design: square components, strong black rules, mono metadata, huge Bricolage numerals, light code blocks, and one terracotta signal accent.
:::

::: manifest-card

### Signal Agency style manifest

- Brand: Signal Agency
- Report mode: AI-search audit dossier
- Shape language: square, ruled, no soft cards
- Primary accent: terracotta signal
- Evidence grammar: verified, partial, inferred, missing
- Best use: client evidence packs, audit findings, roadmap handoffs
:::

## 1. Foundation tokens

::: brand-swatch-grid
::: specimen-card

### Paper surfaces

Use warm paper for the page, alternate paper for secondary panels, and white only for cards that need extra contrast. Purpose: make the report feel reviewed, printed, and evidence-led.
:::

::: specimen-card

### Ink and rules

Near-black ink defines text, borders, separators, and headers. Purpose: hierarchy comes from rules and spacing rather than decoration.
:::

::: specimen-card

### Terracotta signal

Terracotta marks decisive moments: cover emphasis, decision tags, critical findings, and small glyphs. Purpose: one accent keeps attention focused.
:::

::: specimen-card

### Semantic states

Positive, warning, information, and missing states use muted report-safe hues. Purpose: notifications stay legible in PDF and never rely on colour alone.
:::
:::

::: brand-type-scale
::: specimen-card

### Display title

Bricolage Grotesque, tight tracking, large scale. Purpose: create editorial authority on covers and chapter openings.
:::

::: specimen-card

### Body copy

Instrument Sans, readable line length, calm rhythm. Purpose: keep findings legible across HTML, A4, US Letter, and slide exports.
:::

::: specimen-card

### Mono metadata

JetBrains Mono for source IDs, dates, engine names, priorities, and run labels. Purpose: evidence provenance is always scannable.
:::

::: specimen-card

### Code examples

Light paper code panels with terracotta labels. Purpose: keep examples inside the editorial system rather than switching to a dark terminal style.
:::
:::

## 2. Navigation and metadata

::: toc-list
§ 01 — Foundation tokens — colour, type, spacing, radii

§ 02 — Navigation and metadata — cover, manifest, contents

§ 03 — Evidence and notifications — badges, states, callouts

§ 04 — Data blocks — KPIs, tables, bars, ledgers

§ 05 — Recommendation blocks — priorities, preserve/fix, brief, checklist

§ 06 — Export rules — PDF and public-safety checks
:::

::: action-line
**Design rule:** lead with the decision, then show the evidence that supports it. Owner: Strategy · Review every export.
:::

## 3. Evidence and notification variations

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}} {{badge:critical}} {{badge:high}} {{badge:medium}} {{badge:low}}
:::

::: severity-key
::: info-panel severity=critical

### Critical notification

Use for retrieval blockers, missing citations, security/privacy risk, or anything that changes the next action. Shape: square panel, strong rule, explicit label.
:::
::: info-panel severity=high

### Warning notification

Use for partial evidence, parity drift, stale facts, or execution risk. Shape: square panel with warm state colour and concise body copy.
:::
::: info-panel severity=medium

### Information notification

Use for context, method notes, or assumptions. Shape: calm blue-state panel; always include what the reader should do with it.
:::
::: info-panel severity=low

### Positive notification

Use for verified wins and protected patterns. Shape: subdued green-state panel; avoid celebratory language.
:::
:::

::: callout

### Editorial callout

Callouts are reserved for important interpretation, not normal paragraphs. The title states the finding; the body explains why it matters.
:::

::: quote-card
Strong Signal Agency reports separate observed evidence from interpretation, then turn only verified or clearly labelled partial evidence into roadmap items.
:::

## 4. Data block examples

::: stats-strip
::: kpi-card
**3/5**

Engines with at least partial visibility. Source: C001. Trend: +1.
:::
::: kpi-card
**27**

Evidence references captured this window. Source: ledger.
:::
::: kpi-card
**6**

Roadmap items sized for this cycle. Source: priorities.
:::
::: kpi-card
**0**

Private URLs exposed in public export. Source: privacy check.
:::
:::

::: facts-table-wrap

| Element | Purpose | Signal Agency treatment | Verification |
|---|---|---|---|
| Findings table | Dense evidence comparison | Bottom rules, mono headers, evidence badges | Header and cells wrap in PDF |
| KPI card | Executive metric | Ink header, huge numeral, source footer | Source ID and period present |
| Source ledger | Claim traceability | Source ID, summary, confidence | Raw evidence stored separately |
| Brief card | Worker handoff | Inverted ink panel, fixed fields | Acceptance and verification included |

:::

::: visibility-bars
AI Overviews — 78%

Gemini — 54%

ChatGPT — 41%

AI Mode — 38%

Perplexity — 9%
:::

::: ledger-list
C001 — Prompt capture batch — High confidence; raw transcripts stored securely.

C002 — Rendered crawl — High confidence; confirms first-fetch visibility.

C003 — Analytics export — Medium confidence; prioritises commercial pages.

C004 — Parity review — Medium confidence; checks third-party fact drift.
:::

## 5. Recommendation and handoff blocks

::: priority-card priority=critical

### P0 retrieval blocker

Use a priority card when one finding needs executive visibility, owner, due date, source IDs, and verification. {{evidence:verified}}

Owner: Editorial. Due: 2026-W23. Sources: C001, C002.
:::

::: priority-card priority=high

### P1 evidence proximity

Use for important fixes where facts exist but are too far from the claim, table, or source card. {{evidence:partial}}

Owner: Content. Due: 2026-W25. Sources: C003, C004.
:::

::: priority-card priority=medium

### P2 corroboration gap

Use for third-party profile, review, and entity consistency work that supports answer-engine trust. {{evidence:inferred}}

Owner: PR. Due: 2026-W28. Sources: C004.
:::

::: priority-card status=done

### Done pattern

Use the resolved state for shipped work that should be protected in the next iteration. {{evidence:verified}}

Owner: Engineering. Verified: C001.
:::

::: good-bad
::: good-row

### Preserve

- Source IDs beside factual claims.
- Direct-answer opening in first-fetch HTML.
- Clear comparison criteria.
:::
::: bad-row

### Fix

- Client-rendered critical facts.
- Unsupported superlatives.
- Raw evidence in public artifacts.
:::
:::

::: brief-card

### Worker-ready brief

**Task:** Move critical comparison facts into crawlable HTML and attach source IDs.

**Files:** comparison template, source-card component, pricing facts module.

**Acceptance:** direct answer, source IDs, updated date, and criteria table appear in first-fetch HTML.

**Verification:** rerun per-engine prompt set separately and compare citations.
:::

::: checklist-card

- [x] Evidence badges have source IDs.
- [x] PDF exports contain no browser header/footer chrome.
- [ ] Each priority card has owner, due date, and verification.
- [ ] Public artifact contains no private URLs, paths, screenshots, or names.
:::

## 6. Code, source, and export blocks

::: example-card title="Signal Agency code panel"

```text
Report rule: Every recommendation must include source IDs, owner, due date, and verification.
Export rule: Suppress browser PDF header/footer; report chrome belongs in HTML/CSS.
```

:::

::: source-card

### Source-card purpose

Use source cards to explain where evidence lives, what claim it supports, confidence, and whether the raw material is public, internal, confidential, or redacted.
:::

::: privacy-note
**Public artifact rule**

Signal Agency public examples must use placeholders only. Raw transcripts, screenshots, private URLs, client names, and local paths stay in approved secure storage.
:::

::: version-summary
Signal Agency brand style guide specimen · comprehensive report component coverage · public-safe placeholder content
:::
