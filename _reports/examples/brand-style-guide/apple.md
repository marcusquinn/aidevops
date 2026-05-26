<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Apple Brand Style Guide

::: report-cover
**Apple-inspired brand guide for usable report and content production.** This specimen shows how Apple-styled content handles assets, surfaces, type, tagging badges, notifications, data, recommendations, handoffs, and export checks.

Apple-styled content should feel **calm, precise, generous, and product-like**. Use whitespace and restraint first; use blue for action; use colour states sparingly and with enough contrast to survive PDF and print.
:::

::: manifest-card

### Apple production manifest

- Brand: Apple
- Content system: executive summaries, product narratives, launch notes, client recommendations
- Shape language: refined surfaces, soft rounding, subtle depth, minimal visible chrome
- Colour rule: blue is action; graphite is authority; state colours remain calm but visible
- Writing rule: make the next action obvious, then remove everything that does not help the reader decide
- Export rule: light themes use light code blocks and public-safe placeholder evidence
:::

## 1. Brand assets and colour roles

::: brand-asset-grid
::: brand-asset-card accent=light

### Primary mark on light

Use for covers, title pages, and calm executive documents. Keep clearspace generous and avoid nearby badges or dense controls.
:::

::: brand-asset-card accent=dark

### Reverse mark on dark

Use only when the entire module is dark. The mark should feel intentional, not like a contrast workaround.
:::

::: brand-asset-card accent=light

### App or product icon

Use for small cards and preview tiles. Centre it optically and pair with one short label.
:::

::: brand-asset-card accent=dark

### Partner lockup

Use for co-branded pages. Keep both names aligned and let whitespace carry the relationship.
:::
:::

::: brand-swatch-grid
::: swatch-card accent=paper

### White surface

Primary canvas for reading. Use it for report pages, cards, and tables that need a premium quiet feel.
:::

::: swatch-card accent=raised

### Grouped surface

Use for subtle card grouping. The difference must be visible enough to explain structure.
:::

::: swatch-card accent=blue

### Action blue

Use for links, selection, chart focus, and the one action you want the reader to notice.
:::

::: swatch-card accent=ink

### Graphite text

Use for headings and important facts. Softer greys are for metadata, not critical claims.
:::

::: swatch-card accent=amber

### Caution state

Use for pending verification or risk. Keep the hue warm and readable, not faint.
:::

::: swatch-card accent=green

### Success state

Use for verified wins. Pair with a label so the meaning survives grayscale.
:::
:::

## 2. Typography and formatting

::: brand-type-scale
::: type-specimen

### H1 / cover title

**AI visibility readiness**

Large, confident, and simple. One idea per title.
:::

::: type-specimen

### H2 / section title

**What changed this week**

Use section headings to answer what the reader is about to decide.
:::

::: type-specimen

### Body emphasis

Use normal copy for explanation. **Bold** the decision. *Italicise nuance* or a non-blocking caveat.
:::

::: type-specimen

### Metadata

Keep metadata small and quiet: source, date, owner, version. Do not let it compete with the main action.
:::
:::

::: quote-card
Use quotes for direct feedback, reviewer notes, and cited source language. Keep them short and surrounded by whitespace.
:::

## 3. Information tagging badges

Badges are inline metadata. They classify evidence beside a claim; they do not replace a notification or explain an action.

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}} {{badge:critical}} {{badge:high}} {{badge:medium}} {{badge:low}}
:::

::: facts-table-wrap

| Badge | Purpose | Use example | Apple treatment |
|---|---|---|---|
| Verified | Confirmed evidence | “Hero copy appears in first-fetch HTML” | Soft green chip with text label |
| Partial | Incomplete support | “Two sources agree; one is stale” | Warm chip; never hides uncertainty |
| Inferred | Judgement from pattern | “Likely entity drift” | Blue chip; keep caveat nearby |
| Missing | Evidence absent | “No cited source found” | Red chip; do not use as decoration |

:::

## 4. Message states and notifications

::: notification-grid
::: info-panel severity=critical

### Critical alert

**Purpose:** block release until fixed. Use for privacy risk, missing required evidence, or broken export.

*Example:* “The public PDF includes a private source name. Remove it before sharing.”
:::
::: info-panel severity=high

### Warning alert

**Purpose:** show risk that needs attention soon. Use for partial evidence or unresolved owner decisions.

*Example:* “Recommendation is ready, but the owner field is still empty.”
:::
::: info-panel severity=medium

### Information note

**Purpose:** explain scope or method. Use when context helps the reader trust the result.

*Example:* “This review covers A4, US Letter, and slide exports.”
:::
::: info-panel severity=low

### Success note

**Purpose:** record a stable, verified pattern to preserve.

*Example:* “Light code blocks now match the page theme and remain readable.”
:::
:::

## 5. Report component show-and-tell

::: stats-strip
::: kpi-card
**92%**

Priority claims have evidence. **Source:** A001.
:::
::: kpi-card
**4**

Message states tested. **Source:** A002.
:::
::: kpi-card
**12**

Reusable report blocks covered. **Source:** A003.
:::
::: kpi-card
**0**

Private artefacts in public export. **Source:** A004.
:::
:::

::: visibility-bars
Evidence coverage — 92%

Component coverage — 88%

Notification clarity — 84%

Print readiness — 96%
:::

::: facts-table-wrap

| Component | Purpose | Apple treatment | Example content |
|---|---|---|---|
| Cover | First impression | Large title, calm whitespace | “AI visibility readiness” |
| KPI | Executive metric | Rounded quiet card, one number | “92% priority evidence coverage” |
| Notification | Interruptive state | Soft colour, clear recovery action | “Remove private source name” |
| Brief | Delivery handoff | Light panel with concise fields | Task / files / acceptance / verify |

:::

::: ledger-list
A001 — Token audit — **High confidence**; verifies surface, text, accent, and state roles.

A002 — Component review — **High confidence**; checks covers, cards, tables, badges, and alerts.

A003 — Export review — **Medium confidence**; confirms A4, US Letter, and slides outputs.

A004 — Redaction review — **High confidence**; confirms public-safe placeholders.
:::

## 6. Recommendations and handoff

::: priority-card priority=critical

### Critical component issue

Use for a blocker that prevents the report from being trusted or read. {{evidence:verified}}

**Owner:** Design. **Due:** current iteration. **Verify:** the PDF no longer exposes private material.
:::

::: priority-card priority=high

### High-priority refinement

Use for issues that reduce clarity but do not block interpretation. {{evidence:partial}}

**Owner:** Content. **Due:** next pass. **Verify:** owner and acceptance fields are present.
:::

::: priority-card status=done

### Completed pattern

Use for a verified style pattern that should not regress. {{evidence:verified}}

**Owner:** Design. **Verified:** A004. **Preserve:** light code panels and readable state colours.
:::

::: good-bad
::: good-row

### Preserve

- **Spacious rhythm** and short labels.
- Light code blocks on light pages.
- Clear state labels plus colour.
:::
::: bad-row

### Avoid

- Dense tables without breathing room.
- Faint state colours that look identical.
- Random panel widths that imply unrelated meaning.
:::
:::

::: brief-card

### Implementation brief

**Task:** Apply Apple-styled report components to an executive audit.

**Files:** report Markdown, brand renderer CSS, PDF exports.

**Acceptance:** every block has one purpose, clear label, accessible contrast, and print-safe layout.

**Verification:** render HTML, A4, US Letter, and slides; inspect badge, notification, table, and code readability.
:::

::: example-card title="Apple light code panel"

```text
Do: use fewer, clearer blocks.
Do not: use colour when hierarchy, wording, or spacing can solve the problem.
```

:::

::: privacy-note
**Public artifact rule**

Apple-styled public examples must not include private client names, URLs, local paths, screenshots, or raw exports.
:::

::: version-summary
Apple brand style guide specimen · usable production guide · public-safe placeholder content
:::
