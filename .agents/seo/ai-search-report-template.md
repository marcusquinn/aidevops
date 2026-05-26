<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI Search Report Template

Use this report after an AI-search readiness cycle, GEO audit, or SEO audit
that includes LLM visibility evidence. Keep source IDs attached to every
material recommendation so findings can be verified or handed to a worker.

## Report Metadata

- Project:
- Domain or page set:
- Date range:
- Auditor:
- Intent clusters:
- Engines tested: AIO, Gemini, ChatGPT, AI Mode, Perplexity
- Evidence ledger location:
- Public-export mode: internal, confidential, or redacted public example

## 1. Executive Summary

| Item | Finding | Business impact | Source IDs |
|------|---------|-----------------|------------|
| Highest-value opportunity | | | |
| Highest-risk visibility gap | | | |
| Fastest hygiene win | | | |
| Evidence confidence | | | |

Summarise outcomes in business language. Do not claim AI Share of Voice unless
the per-engine lines in section 3 support the summary.

Presentation pattern: lead with a cover manifest, 3-4 large KPI cards, one
decision/action line, and an inline table of contents. Each KPI needs a source
ID, period/window, and trend or status label.

## 2. Method

- Inputs: priority pages, target intents, competitor/entity set, analytics or
  conversion proxy, crawl/index checks, third-party profiles, and engine runs.
- Page-type framework:
  `seo-audit-skill/aeo-geo-patterns/04-page-type-tactic-matrix.md`.
- Scoring framework: `seo/ai-search-scoring.md`.
- Evidence rule: every material recommendation must cite `source_id` values
  from section 5.
- Engine rule: report AIO, Gemini, ChatGPT, AI Mode, and Perplexity separately;
  only then add an optional aggregate summary.

## 3. Weighted Scorecard

| Page or cluster | Page type | Business value | Page-type applicability | Retrieval eligibility | Evidence strength | Effort | Confidence | Freshness | Third-party breadth | Engine behaviour | Priority |
|-----------------|-----------|----------------|-------------------------|-----------------------|-------------------|--------|------------|-----------|---------------------|------------------|----------|
| | | | | | | | | | | | |

### Per-Engine Visibility Lines

| Engine | Query/prompt set | Mentions | Citations | Cited URLs | Missing or wrong facts | Source IDs | Notes |
|--------|------------------|----------|-----------|------------|------------------------|------------|-------|
| AIO | | | | | | | |
| Gemini | | | | | | | |
| ChatGPT | | | | | | | |
| AI Mode | | | | | | | |
| Perplexity | | | | | | | |

Render per-engine coverage as a table plus a horizontal visibility-bars block
when a percentage or score is defensible. Keep every engine separate; aggregate
bars are secondary.

## 4. Page-Type Findings

| Page | Page type | Required tactic gaps | Conditional opportunities | Hygiene items | Avoided tactics | Source IDs |
|------|-----------|----------------------|---------------------------|---------------|-----------------|------------|
| | PDP/category/homepage/article/local/SaaS feature/pricing/comparison/glossary/use-case/research/report | | | | | |

Use visible FAQ recommendations only where the page type supports them.
Treat `FAQPage` schema and other structured data as hygiene unless a validation
error blocks rich-result eligibility or entity clarity.

## 5. Evidence Ledger

| source_id | Type | URL/path | Captured date | Claim supported | Confidence | Freshness risk |
|-----------|------|----------|---------------|-----------------|------------|----------------|
| S001 | | | | | | |

Allowed source types: crawl record, page section, analytics snapshot, SERP
capture, AIO run, Gemini run, ChatGPT run, AI Mode run, Perplexity run,
third-party profile, review, policy, certificate, research data, log sample.

For client-safe exports, include a short source-ledger block with source IDs,
titles, summaries, confidence bars, and storage location; keep raw transcripts,
screenshots, private URLs, and local paths out of the public artifact.

## 6. Finding-to-Taxonomy Map

| Finding | Taxonomy component | Why it matters | Source IDs |
|---------|--------------------|----------------|------------|
| | Grounding eligibility | Can the engine retrieve and trust the page? | |
| | Fan-out coverage | Does the site answer the sub-queries behind the intent? | |
| | Criteria alignment (GEO) | Does the page match buyer or evaluator criteria? | |
| | Snippet survivability (SRO) | Can a concise answer survive extraction? | |
| | Fact integrity | Are canonical facts consistent and contradiction-free? | |
| | Autonomous discoverability | Can an agent find and complete the task? | |
| | Citation monitoring | Do per-engine mentions and citations move after changes? | |
| | Page-type tactic fit | Are tactics weighted for PDP, category, homepage, article, local, SaaS feature, pricing, comparison, glossary, use-case, or research/report intent? | |

## 7. Roadmap

| Priority | Recommendation | Page(s) | Owner | Effort | Verification | Source IDs |
|----------|----------------|---------|-------|--------|--------------|------------|
| P0 | | | | | | |
| P1 | | | | | | |
| P2 | | | | | | |

Write recommendations as worker-ready tasks: target files or pages, reference
pattern, expected change, and verification command or measurement.

For executive-ready reports, use one priority card per material finding. Include
priority, status/evidence badge, owner, due date, source IDs, and a single
finding paragraph. Use preserve/fix split blocks after the roadmap to prevent
working patterns from being lost during remediation.

## 8. Verification Plan

- Re-run crawl/index checks for changed pages.
- Re-run per-engine prompt/query sets for AIO, Gemini, ChatGPT, AI Mode, and
  Perplexity with dates and source IDs.
- Compare weighted scorecard deltas against baseline.
- Validate schema only as hygiene; verify visible content and evidence first.
- Re-check third-party profile parity for facts changed on owned pages.
- Assign one checklist owner per row; do not combine prompt reruns across engines.

## 9. Custom-Agent and Routine Handoff

| Handoff | Trigger | Context to include | Verification |
|---------|---------|--------------------|--------------|
| Custom agent | Repeated audit pattern requires a reusable specialist workflow. | Prompt, target pages, source IDs, taxonomy component, expected report output. | Dry-run on one page or cluster. |
| Routine | Monthly or quarterly monitoring is needed. | Engine list, query set, evidence ledger path, scorecard path, cadence. | First scheduled run posts scorecard and evidence ledger. |
| Worker task | A concrete remediation is ready. | File/page path, before/after pattern, source IDs, acceptance criteria. | Lint, crawl, or per-engine re-test evidence. |
