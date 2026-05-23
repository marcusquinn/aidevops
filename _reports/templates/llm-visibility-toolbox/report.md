<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# LLM Visibility Toolbox

::: report-cover
**A Markdown-canonical playbook for AI search visibility.** Use it to turn source evidence, page-type weighting, and answer-engine behaviour into roadmap-ready recommendations.

Audience: SEO, content, engineering, and leadership teams. Export rule: one HTML preview; PDF profiles for A4, Letter, and 16:9 decks.
:::

## Executive summary

LLM visibility is an evidence system, not a single checklist. The best programmes make priority pages retrieval-ready, criteria-complete, citation-worthy, technically fetchable, and corroborated by third-party sources. {{evidence:verified}}

Recommendations must be weighted by page type. A homepage, SaaS feature page, comparison page, pricing page, article, product page, local/YMYL page, and research asset need different tactics, owners, and verification paths. {{evidence:verified}}

::: badge-row
{{evidence:verified}} {{evidence:partial}} {{evidence:inferred}} {{evidence:missing}}
:::

::: stats-strip
::: stat-card
**5**

Answer engines reported separately.
:::
::: stat-card
**8**

Page types weighted before recommendations.
:::
::: stat-card
**4**

Evidence strengths used in source ledgers.
:::
::: stat-card
**1**

Canonical Markdown source.
:::
:::

::: action-line
**Operator action:** collect source IDs first, then interpret findings into recommendations with owners, acceptance criteria, and rerun steps.
:::

## Source ledger pattern

::: facts-table-wrap

| Source ID | Evidence type | Use in report | Verification |
|---|---|---|---|
| S001 | Prompt capture | Per-engine citation presence | AIO, Gemini, ChatGPT, AI Mode, and Perplexity recorded separately |
| S002 | Raw/rendered crawl | Retrieval eligibility | Important claims visible on first fetch |
| S003 | Page inventory | Page-type weighting | URL mapped to homepage, feature, comparison, article, local, PDP, or report |
| S004 | Third-party profile | Corroboration strength | Facts match owned canonical entity table |
| S005 | Analytics/search data | Business value and priority | Priority URL cluster tied to demand or revenue |
:::

::: source-card
### Source-card rule

Every roadmap item should cite source IDs, observed date, confidence, owner, and the command or routine that verifies completion.
:::

## Highest-impact tactics

::: details-note
### Weight before recommending

Do not apply all tactics to all pages. Score page-type fit, retrieval eligibility, source proximity, corroboration, freshness, confidence, impact, and effort before roadmap sequencing.
:::

::: facts-table-wrap

| Tactic | Evidence | Best page types | Why it matters | Verification |
|---|---|---|---|---|
| Direct-answer opening | {{evidence:verified}} | Article, glossary, comparison, feature, local | Concise first-paragraph claims are easier to retrieve and cite. | Rendered first 300 words include answer, source, and updated date |
| Source cards near claims | {{evidence:verified}} | Research, comparison, YMYL, feature | Engines need nearby proof to trust and quote claims. | Source ID appears beside factual claim and in ledger |
| Third-party corroboration | {{evidence:verified}} | SaaS, ecommerce, local, YMYL | Answer engines cross-check owned claims against outside sources. | Profile parity and source breadth review |
| Bot-friendly first fetch | {{evidence:verified}} | All priority pages | Hidden or blocked content cannot be cited. | Raw/rendered crawl, robots, sitemap, and logs |
| Entity consistency | {{evidence:partial}} | Homepage, about, local, profiles | Contradictory facts reduce answer confidence. | Canonical entity table and third-party parity |
| FAQPage schema | {{evidence:inferred}} | Hygiene only | Structured data helps clarity but does not replace visible evidence. | Schema validation plus visible-content check |
:::

## Page-type matrix

::: facts-table-wrap

| Page type | Required tactics | Conditional tactics | Devalue or avoid |
|---|---|---|---|
| Homepage | Entity facts, category clarity, proof, crawlable nav | Original stats, comparison links | Long FAQ as primary GEO tactic |
| SaaS feature | Criteria block, use cases, integrations, proof | Demo video transcript, benchmark table | Generic benefit copy without source IDs |
| Pricing | Plan facts, constraints, comparison table | Purchase-relevant visible FAQ | Hidden pricing screenshots only |
| Comparison | Direct answer, feature/pricing table, alternatives, source cards | Third-party review quotes | Unsupported “best” claims |
| Article/guide | Direct answer, question headings, stats, expert quotes | Glossary sidebar, summary box | Thin filler or stale facts |
| Product/PDP | Specs, reviews, availability, canonical descriptions | Video transcript, product schema | Flat B2B SaaS checklist |
| Local/YMYL | Credentials, service area, policies, disclaimers | Practitioner bios, local citations | Unsupported advice |
| Research/report | Methodology, dataset, source cards, findings | Embeddable charts | PDF-only content without HTML summary |
:::

::: industry-card
### Industry-fit reminder

SaaS, ecommerce, local, and YMYL pages require different proof sources. Map the page type before assigning a tactic.
:::

## Tactic card examples

::: tactic-card
### Direct-answer opening

- What: answer the query plainly in the first paragraph.
- Why: extractive systems need self-contained claims with nearby proof.
- How: pair answer, source ID, author/update date, and supporting table.
- Verify: rerun per-engine prompts and compare cited URL movement.
:::

::: tactic-card
### Bot-friendly first fetch

- What: SSR or pre-render important content, allow relevant crawlers, and keep key text visible.
- Why: invisible or blocked content cannot be cited.
- How: compare raw HTML, rendered DOM, robots, sitemap, and logs.
- Verify: monthly crawl plus AI/search bot log review.
:::

::: good-bad
::: good-row
### Strong pattern

Direct answer, evidence badge, source ID, visible methodology, updated date, and crawlable comparison table.
:::
::: bad-row
### Weak pattern

Image-only proof, unsupported superlatives, client-rendered claims, and schema added without visible evidence.
:::
:::

## Myths and caveats

::: myth-callout
### Myth

Adding FAQPage schema is enough to become GEO-ready.

### Reality

FAQPage is hygiene unless visible FAQ content genuinely fits page type and query fan-out.
:::

::: example-card
```text
Worker brief: update /compare/example with source IDs S001-S004,
visible comparison evidence, third-party corroboration, and retest steps.
Acceptance: AIO, Gemini, ChatGPT, AI Mode, and Perplexity results are recorded separately.
```
:::

## Roadmap template

::: priority-group priority=high
### Priority rule

Start with revenue pages that fail retrieval eligibility or evidence proximity before optional schema enhancements.
:::

::: facts-table-wrap

| Priority | Recommendation | Applies to | Owner | Verification | Source IDs |
|---|---|---|---|---|---|
| P0 | Fix retrieval blockers on revenue pages. | Homepage, pricing, feature, PDP, local | SEO + engineering | Raw/rendered crawl, robots, sitemap, logs | S002, S005 |
| P1 | Add source cards and original evidence. | Comparison, article, research/report | Content + subject expert | Source ledger and citation checks | S001, S003 |
| P1 | Build third-party corroboration. | SaaS, local, ecommerce | Marketing/PR | Profile parity and source breadth | S004 |
| P2 | Improve schema and metadata. | All page types | SEO + engineering | Schema validation plus visible-content check | S002 |
:::

## Verification checklist

::: checklist-card

- Validate evidence badges and source IDs before export.
- Render HTML with the chosen DESIGN.md-backed template.
- Review table wrapping, badge visibility, source-card readability, and sticky TOC behaviour.
- Export A4/Letter PDF for documents and 16:9 PDF for decks.
- For client-custom reports, rerun live evidence collection before interpretation.
- For recurring reports, create a custom routine with deterministic collection and report-agent interpretation.
:::
