<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Page-Type Tactic Matrix

Use this matrix to weight AEO/GEO recommendations by page intent before writing
copy or audit notes. Page types covered: PDP, category, homepage, article,
local, SaaS feature, pricing, comparison, glossary, use-case, and
research/report pages.

## Legend

| Tag | Meaning |
|-----|---------|
| `required` | Missing tactic materially reduces retrieval, selection, or conversion usefulness for this page type. |
| `conditional` | Use when the page intent, query fan-out, or available evidence supports it. |
| `hygiene` | Keep valid and consistent, but do not treat as a primary GEO lever. |
| `avoid` | Usually harms focus, adds unsupported claims, or creates irrelevant SERP/LLM signals. |

## Tactic Weighting by Page Type

| Tactic | PDP | category | homepage | article | local | SaaS feature | pricing | comparison | glossary | use-case | research/report |
|--------|-----|----------|----------|---------|-------|--------------|---------|------------|----------|----------|-----------------|
| Criteria-matching summary in first 200-300 words | required | required | conditional | conditional | required | required | required | required | conditional | required | conditional |
| Evidence sandwich with source IDs | required | conditional | conditional | required | required | required | required | required | hygiene | required | required |
| Visible FAQ block with search-language questions | conditional | conditional | hygiene | conditional | conditional | conditional | required | conditional | conditional | conditional | conditional |
| `FAQPage` schema | hygiene | hygiene | avoid | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene |
| Page-specific structured data validation | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene | hygiene |
| Pricing, packaging, availability, or eligibility facts | required | conditional | conditional | avoid | conditional | conditional | required | required | avoid | conditional | avoid |
| Third-party corroboration breadth | required | conditional | conditional | required | required | required | conditional | required | avoid | required | required |
| Comparison table against alternatives or criteria | conditional | conditional | avoid | conditional | conditional | conditional | conditional | required | avoid | required | conditional |
| Freshness marker and dated review cadence | required | required | conditional | required | required | required | required | required | conditional | required | required |
| Canonical fact parity across owned and third-party pages | required | required | required | conditional | required | required | required | required | hygiene | required | conditional |

## Page-Type Notes

- **PDP**: optimise for product/category retrieval, feature extraction,
  availability, price, differentiators, and proof. Treat Product schema as
  hygiene; the visible facts and evidence decide citation usefulness.
- **category**: summarise category coverage, buyer criteria, product variants,
  inventory logic, and internal links to PDPs. Avoid generic buying-guide copy
  without evidence.
- **homepage**: reinforce entity clarity, category terms, proof, and navigation.
  Avoid forcing FAQ blocks unless they answer real branded or navigational
  questions.
- **article**: lead with the direct answer, cite source IDs for material claims,
  and use visible FAQ only when People Also Ask or fan-out branches justify it.
- **local**: prioritise NAP parity, service-area detail, opening hours,
  licensing, reviews, and locally verifiable proof. LocalBusiness schema remains
  hygiene, not a substitute for visible evidence.
- **SaaS feature**: expose use cases, integrations, limits, screenshots or demo
  proof, and third-party profile parity for the same feature naming.
- **pricing**: make plan names, units, exclusions, renewal terms, and latest
  update dates crawlable. Visible FAQ can clarify packaging; `FAQPage` schema is
  still hygiene.
- **comparison**: require neutral criteria, dated facts, strengths, trade-offs,
  and competitor source IDs. Avoid unsupported superiority claims.
- **glossary**: keep definitions concise, link to deeper pages, and avoid
  pricing or comparison sections that dilute informational intent.
- **use-case**: show audience, trigger scenario, workflow, results, proof, and
  links to feature/PDP pages.
- **research/report**: require methodology, sample, date, limitations, data
  source IDs, and citation-ready charts or findings.

## FAQ and Schema Devaluation Rules

- Treat visible FAQs as content, not markup. They are useful when the page type
  supports question-led objections, packaging clarification, local service
  details, or fan-out branches.
- Treat `FAQPage` and other schema as validation hygiene. Schema can clarify
  entities for crawlers, but it should not outrank missing visible evidence,
  weak criteria coverage, stale facts, or low business value.
- Do not add FAQ sections solely to justify `FAQPage` schema. Mark the tactic
  `avoid` when questions are not natural for the page intent.
- When schema conflicts with visible copy, fix the visible canonical fact first,
  then update markup to match.
