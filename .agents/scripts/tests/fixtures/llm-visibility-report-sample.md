<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# LLM Visibility Report

::: report-cover
**Evidence-first AI search reporting** for AIO, Gemini, ChatGPT, AI Mode, and Perplexity.

Report date: 2026-05-23. Scope: sample renderer fixture.
:::

## Executive Summary

The site appears in AI Overviews and answer-engine citations for priority service prompts. {{evidence:verified}}

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}}
:::

::: stats-strip
::: stat-card
**82**

AIO citation score.
:::
::: stat-card
**5**

Answer engines tracked separately.
:::
::: stat-card
**12**

Source IDs in the ledger.
:::
::: stat-card
**3**

Priority page types weighted.
:::
:::

::: action-line
**Next action:** strengthen evidence cards on comparison and research pages before rerunning prompt tests.
:::

## Method

- Run SEO AI readiness across AIO, Gemini, ChatGPT, AI Mode, and Perplexity.
- Capture prompts, source IDs, screenshots, crawl exports, and remediation notes.

::: details-note
### Method note

FAQPage schema is treated as hygiene. Visibility recommendations are weighted by page type and verified per engine.
:::

## Weighted Scorecard

::: facts-table-wrap

| Component | Score | Badge |
|---|---:|---|
| AIO | 82 | {{evidence:verified}} |
| Gemini | 74 | {{evidence:partial}} |
| ChatGPT | 68 | {{evidence:inferred}} |
| AI Mode | 51 | {{evidence:partial}} |
| Perplexity | 0 | {{evidence:missing}} |
:::

::: myth-callout
### Myth

Adding FAQPage schema alone is a primary GEO tactic.

### Fact

FAQPage is hygiene unless visible FAQ content genuinely matches query fan-out and page type.
:::

## Page-Type Findings

- Product detail pages include source-backed claims. {{evidence:verified}}
- Comparison pages need stronger evidence cards. {{evidence:partial}}
- Research pages have inferred opportunity clusters. {{evidence:inferred}}

::: good-bad
::: good-row
### Good pattern

Lead with a direct answer, source ID, author, update date, and supporting data table.
:::
::: bad-row
### Weak pattern

Hide the answer behind client-side rendering or unsupported claims.
:::
:::

::: tactic-card
### Direct-answer opening

- What: answer the query plainly in the first paragraph.
- Why: extractive answer systems need concise, quotable claims with nearby proof.
- Verify: rerun per-engine prompts and compare cited URL movement.
:::

::: example-card
```text
Question: What evidence proves this claim?
Answer: Cite source ID S-004, report date, owner, and page URL.
```
:::

::: industry-card
### SaaS comparison pages

Prioritise third-party corroboration, clear feature tables, and source-backed claims.
:::

::: priority-group priority=high
### High priority remediation

Refresh weak comparison pages with source cards and visible evidence summaries.
:::

::: checklist-card
### Verification checklist

- AIO prompt rerun captured.
- Gemini source export saved.
- ChatGPT transcript linked to source IDs.
- Perplexity gap recorded when no citation appears.
:::

## Evidence Ledger

Source: AIO capture and crawl export for priority prompts.
Source card: Gemini citation export and manual verification worksheet.
Source: ChatGPT prompt transcript with source IDs.
Source card: Perplexity query set showing missing citation coverage.

::: source-card
### Source S-004

Manual prompt capture, crawl export, screenshot, and remediation note.
:::

## Roadmap

- Add cited source cards to weak pages.
- Rerun `/seo-ai-readiness example.com` after remediation.

## Verification

- Render this Markdown fixture to HTML.
- Print or export the HTML to PDF from the browser print dialog.
