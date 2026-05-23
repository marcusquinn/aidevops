<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Client AI Search Audit

::: report-cover
**Placeholder-safe client report template** for AI Overviews, Gemini, ChatGPT, AI Mode, and Perplexity visibility.

Prepared for: Example client. Scope: example.com priority pages. Replace placeholders only after live evidence collection.
:::

## Executive summary

Example client appears in some answer-engine responses for category and comparison prompts, but source coverage is uneven. Priority gaps are retrieval eligibility, source-card proximity, and third-party corroboration parity. {{evidence:partial}}

::: stats-strip
::: stat-card
**3/5**

Engines with at least partial visibility.
:::
::: stat-card
**12**

Priority URLs reviewed.
:::
::: stat-card
**27**

Source IDs captured.
:::
::: stat-card
**6**

P0/P1 roadmap items.
:::
:::

::: action-line
**Decision:** prioritise comparison and pricing pages before lower-impact article refreshes.
:::

## Engine findings

::: facts-table-wrap

| Engine | Finding | Evidence | Next action |
|---|---|---|---|
| AIO | Brand cited for two comparison prompts. | {{evidence:verified}} | Add source cards to pages with citations but weak snippets. |
| Gemini | Mentions brand but misses pricing constraints. | {{evidence:partial}} | Add visible plan constraints and updated date. |
| ChatGPT | Recommendation inferred from third-party profiles. | {{evidence:inferred}} | Improve profile parity and owned corroboration. |
| AI Mode | Partial feature coverage, no comparison citation. | {{evidence:partial}} | Strengthen direct-answer opening on comparison page. |
| Perplexity | No citation found in priority prompt set. | {{evidence:missing}} | Build third-party corroboration and rerun prompt set. |
:::

## Source ledger

::: facts-table-wrap

| Source ID | Source | Confidence | Notes |
|---|---|---|---|
| C001 | Prompt capture batch | High | Use raw transcript plus screenshot in private evidence folder. |
| C002 | Rendered crawl | High | Confirms client-rendered sections missing from first fetch. |
| C003 | Analytics export | Medium | Prioritises pages with commercial intent. |
| C004 | Third-party profile parity review | Medium | Category and pricing facts mismatch owned page. |
:::

::: source-card
### Privacy rule

Public issues, PRs, and examples must not include private client names, private URLs, local paths, screenshots, or raw exports. Use placeholders and keep evidence in the approved private storage location.
:::

## Page-type weighted findings

::: priority-group priority=critical
### P0: Comparison page retrieval gap

Comparison content answers the right intent but key criteria are below client-rendered sections. Move the answer, feature table, pricing caveats, and source IDs into crawlable first-fetch HTML. {{evidence:verified}}
:::

::: priority-group priority=high
### P1: Pricing facts lack nearby evidence

The pricing page states plan limits but lacks updated date, source card, and consistent third-party parity. Add canonical values and cite source IDs near the claims. {{evidence:partial}}
:::

::: good-bad
::: good-row
### Preserve

Clear category positioning, strong customer proof, and relevant comparison intent coverage.
:::
::: bad-row
### Fix

Hidden content, unsupported superlatives, stale profile facts, and Perplexity source gaps.
:::
:::

## Implementation brief

::: example-card
```text
Task: Improve /compare/example-vs-competitor for AI search citation readiness.
Files: comparison page template, pricing facts component, source-card component.
Acceptance: raw HTML contains direct answer, source IDs C001-C004, updated date, and criteria table.
Verification: rerun AIO, Gemini, ChatGPT, AI Mode, and Perplexity prompt set separately.
```
:::

## Verification checklist

::: checklist-card

- Confirm live evidence collection date and source IDs.
- Re-run crawl after implementation and compare raw vs rendered HTML.
- Re-run per-engine prompt set and record each answer separately.
- Update third-party profile parity table.
- Convert recurring monitoring into a monthly report routine.
:::
