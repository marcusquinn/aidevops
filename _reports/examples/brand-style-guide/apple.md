<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Apple Brand Style Guide

::: report-cover
**Apple-inspired report presentation guide.** Use this specimen to see how Apple-styled reports handle evidence, metrics, recommendations, notifications, and handoff blocks with restraint.

Apple styling is quiet, spacious, precise, and product-like. The report should feel polished and intentional: soft hierarchy, few borders, generous whitespace, concise copy, and calm state colour.
:::

::: manifest-card

### Apple style manifest

- Brand: Apple
- Report mode: polished executive/product evidence report
- Shape language: refined surfaces, subtle rounding, minimal visible chrome
- Primary accent: Apple blue
- Evidence grammar: clear status labels, calm colour, no visual noise
- Best use: executive summaries, product narratives, client recommendations
:::

## 1. Foundation tokens

::: brand-swatch-grid
::: specimen-card

### White and near-white surfaces

Use white as the primary canvas and light neutrals for grouped content. Purpose: create focus and make the report feel effortless.
:::

::: specimen-card

### Graphite text

Use high-contrast graphite for body text and softer grey for metadata. Purpose: clarity without visual heaviness.
:::

::: specimen-card

### Apple blue action

Use blue for links, active states, selected navigation, and primary action. Purpose: direct attention without competing with content.
:::

::: specimen-card

### State colour family

Use soft red, amber, blue, and green notification hues with rounded shapes. Purpose: status should feel system-native, not alarming.
:::
:::

::: brand-type-scale
::: specimen-card

### Large title

Use confident, clean sans-serif display type with tight but readable tracking. Purpose: premium hierarchy.
:::

::: specimen-card

### Reading copy

Use generous leading and paragraph spacing. Purpose: make executive reading feel light and fast.
:::

::: specimen-card

### Metadata

Use small sans-serif labels, not a heavy terminal-style mono. Purpose: keep provenance present but quiet.
:::

::: specimen-card

### Code examples

Use light code panels with subtle borders and rounded controls. Purpose: technical details should feel integrated with the product system.
:::
:::

## 2. Report element index

::: toc-list
01 — Foundations — surfaces, type, colour, radii

02 — Notifications — success, warning, information, critical

03 — Data — KPI cards, tables, bars, source ledger

04 — Recommendations — priorities, good/bad, brief, checklist

05 — Export — code, source card, privacy note
:::

::: action-line
**Design rule:** make the next action obvious, then remove everything that does not help the reader decide.
:::

## 3. Notification variations

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}} {{badge:critical}} {{badge:high}} {{badge:medium}} {{badge:low}}
:::

::: severity-key
::: info-panel severity=critical

### Critical

Use for blockers. Apple styling should keep the shape composed: rounded panel, concise title, direct recovery action.
:::
::: info-panel severity=high

### Warning

Use for risk and partial evidence. Keep copy neutral and specific; avoid dramatic language.
:::
::: info-panel severity=medium

### Information

Use for method, assumptions, or supporting context. Keep it quiet and readable.
:::
::: info-panel severity=low

### Success

Use for verified wins and shipped work. Focus on what is now safe to preserve.
:::
:::

::: quote-card
Apple-styled reports should make complexity feel resolved: every component has a purpose, every state has a label, and every recommendation has a clear next step.
:::

## 4. Data and evidence examples

::: stats-strip
::: kpi-card
**92%**

Evidence coverage for priority claims. Source: style audit.
:::
::: kpi-card
**4**

Notification states validated for report use.
:::
::: kpi-card
**12**

Core report components shown in this specimen.
:::
::: kpi-card
**0**

Private artifacts included in public export.
:::
:::

::: facts-table-wrap

| Element | Purpose | Apple treatment | Verification |
|---|---|---|---|
| Cover | First impression | Large type, calm whitespace | Title fits A4 and slides |
| KPI | Executive metric | Rounded quiet card, large value | Period and source included |
| Notification | State communication | Soft colour and explicit label | Meaning survives grayscale |
| Brief | Action handoff | Clean field structure | Owner and acceptance present |

:::

::: visibility-bars
Evidence coverage — 92%

Component coverage — 88%

Notification clarity — 84%

Print readiness — 96%
:::

::: ledger-list
A001 — Token audit — High confidence; verifies surface, text, accent, and state roles.

A002 — Component review — High confidence; checks cover, cards, tables, badges, and briefs.

A003 — Export review — Medium confidence; confirms A4, US Letter, and slides outputs.
:::

## 5. Recommendation examples

::: priority-card priority=critical

### Critical component issue

Use for a blocker that prevents the report from being trusted or read. {{evidence:verified}}

Owner: Design. Due: Current iteration. Source: A002.
:::

::: priority-card priority=high

### High-priority refinement

Use for issues that reduce clarity but do not block interpretation. {{evidence:partial}}

Owner: Content. Due: Next pass. Source: A001.
:::

::: priority-card priority=medium

### Medium enhancement

Use for optional improvements that polish the reader experience. {{evidence:inferred}}

Owner: Design systems. Due: Backlog. Source: A003.
:::

::: priority-card status=done

### Completed pattern

Use to show a verified style pattern that should not regress. {{evidence:verified}}

Owner: Design. Verified: A001.
:::

::: good-bad
::: good-row

### Preserve

- Spacious section rhythm.
- Short, direct labels.
- Minimal chrome around evidence.
:::
::: bad-row

### Avoid

- Dense tables without breathing room.
- Over-coloured panels.
- Decorative elements that do not clarify meaning.
:::
:::

::: brief-card

### Implementation brief

**Task:** Apply Apple-styled report components to an executive audit.

**Files:** report Markdown, brand renderer CSS, PDF exports.

**Acceptance:** every block has one purpose, clear label, accessible contrast, and print-safe layout.

**Verification:** render HTML, A4, US Letter, and slides; inspect notification and table readability.
:::

::: checklist-card

- [x] Cover and manifest are brand-specific.
- [x] Every state uses text plus colour.
- [ ] Every KPI includes source and period.
- [ ] Tables and notification panels remain readable in PDF.
:::

## 6. Export and source examples

::: example-card title="Apple-styled report rule"

```text
Use fewer, clearer blocks. If a component does not help the reader decide, remove it.
```

:::

::: source-card

### Source-card purpose

Use source cards for traceability, but keep them quiet: source ID, summary, confidence, and access rule are enough for the main report.
:::

::: privacy-note
**Public artifact rule**

Apple-styled public examples must not include private client names, URLs, local paths, screenshots, or raw exports.
:::

::: version-summary
Apple brand style guide specimen · comprehensive report component coverage · public-safe placeholder content
:::
